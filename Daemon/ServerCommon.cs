// ServerCommon.cs
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Management.Automation;
using System.Security.AccessControl;
using System.Security.Principal;

public static class ServerCommon
{
    private const string PipeName = "ControlledAdminCommand";

    private static CancellationTokenSource _cts = null!;
    private static Task _listenerTask = null!;
    private static Dictionary<string, string> _scriptMap = null!;
    private static string _baseDir = null!;

    private static int _readTimeout;
    private static int _writeTimeout;

    private static int _maxClients;

    public static void Start()
    {
        _cts = new CancellationTokenSource();

        _baseDir = Environment.GetEnvironmentVariable("CONTROLLED_ADMIN_COMMAND_DAEMON_DIR")
                   ?? AppContext.BaseDirectory;

        if (!int.TryParse(Environment.GetEnvironmentVariable("CONTROLLED_ADMIN_COMMAND_READ_TIMEOUT"), out _readTimeout))
            _readTimeout = 10000;

        if (!int.TryParse(Environment.GetEnvironmentVariable("CONTROLLED_ADMIN_COMMAND_WRITE_TIMEOUT"), out _writeTimeout))
            _writeTimeout = 10000;

        if (!int.TryParse(Environment.GetEnvironmentVariable("CONTROLLED_ADMIN_COMMAND_MAX_CLIENTS"), out _maxClients))
            _maxClients = 10;

        if (_maxClients < 1)
            _maxClients = 1;

        LoadScripts();

        _listenerTask = Task.Run(() => ListenLoop(_cts.Token));

        Console.WriteLine("Server started...");
    }

    public static void Stop()
    {
        Console.WriteLine("Stopping server...");
        _cts.Cancel();

        try { _listenerTask.Wait(); }
        catch { }

        Console.WriteLine("Server stopped.");
    }

    private static void LoadScripts()
    {
        var jsonPath = Path.Combine(_baseDir, "Scripts.json");
        if (!File.Exists(jsonPath))
            throw new FileNotFoundException($"Scripts.json not found in {_baseDir}.");

        var json = File.ReadAllText(jsonPath);
        if (string.IsNullOrEmpty(json))
            throw new Exception("Scripts.json is empty.");

        _scriptMap = JsonSerializer.Deserialize<Dictionary<string, string>>(json, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = false
        }) ?? new Dictionary<string, string>();
    }

    private static async Task ListenLoop(CancellationToken ct)
    {
        List<Task> clientTasks = new List<Task>();

        var pipeSecurity = new PipeSecurity();

        Console.WriteLine("Setting up pipe security...");

        PipeAccessRights fullControl =
            PipeAccessRights.ReadWrite |
            PipeAccessRights.CreateNewInstance |
            PipeAccessRights.Delete |
            PipeAccessRights.ReadAttributes |
            PipeAccessRights.WriteAttributes |
            PipeAccessRights.ReadExtendedAttributes |
            PipeAccessRights.WriteExtendedAttributes |
            PipeAccessRights.ReadPermissions |
            PipeAccessRights.ChangePermissions |
            PipeAccessRights.TakeOwnership;

        pipeSecurity.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.WorldSid, null),
            fullControl,
            AccessControlType.Allow));

        while (!ct.IsCancellationRequested)
        {
            Console.WriteLine("Checking for available task slot (or cleaning up completed tasks)...");

            while (!ct.IsCancellationRequested)
            {
                if (clientTasks.Count < _maxClients)
                    break;
                clientTasks.RemoveAll(t => t.IsCompleted);
                Thread.Sleep(50);
            }

            NamedPipeServerStream serverStream;

            try
            {
                Console.WriteLine("Creating named pipe server stream...");
                serverStream = NamedPipeServerStreamAcl.Create(
                    PipeName,
                    PipeDirection.InOut,
                    _maxClients,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous,
                    0,
                    0,
                    pipeSecurity);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Failed to create named pipe server stream: {ex.Message}");
                await Task.Delay(1000, ct);
                continue;
            }

            try
            {
                Console.WriteLine("Waiting for client connection...");
                await serverStream.WaitForConnectionAsync(ct);
                Console.WriteLine("Client connected.");
            }
            catch (Exception ex)
            {
                Console.WriteLine("Failed to connect to client or operation cancelled: " + ex.Message);
                serverStream.Dispose();
                continue;
            }

            Console.WriteLine("Running and recording client task...");
            var clientTask = Task.Run(() => HandleClient(serverStream));
            clientTasks.Add(clientTask);
        }

        Console.WriteLine("Waiting for client tasks to finish...");
        try { Task.WaitAll(clientTasks.ToArray(), -1); } catch { }
    }

    // -------------------------
    // Client Handling
    // -------------------------

    private static async Task HandleClient(NamedPipeServerStream stream)
    {
        using (stream)
        {
            string requestJson;
            try
            {
                requestJson = await ReadFrame(stream);
                if (requestJson == null) return;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Failed to read frame from client: {ex.Message}");
                return;
            }

            string user = "<unknown>";
            try
            {
                bool userRead = false;
                stream.RunAsClient(() =>
                {
                    user = WindowsIdentity.GetCurrent().Name;
                    userRead = true;
                });
                if (!userRead)
                    throw new Exception("Failed to read user identity.");
                Console.WriteLine($"Pipe server stream created for user: {user}");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Failed to get client user identity: {ex.Message}");
                stream.Dispose();
                return;
            }

            var response = await ExecuteCommand(requestJson, user);
            try
            {
                await WriteFrame(stream, response);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Failed to write frame to client: {ex.Message}");
                return;
            }
        }
    }

    private static async Task<int> ReadWithTimeout(
        Stream stream, byte[] buffer, int offset, int count, int timeoutMs)
    {
        using var cts = new CancellationTokenSource();
        var readTask = stream.ReadAsync(buffer, offset, count, cts.Token);
        var timeoutTask = Task.Delay(timeoutMs);

        var completed = await Task.WhenAny(readTask, timeoutTask);
        if (completed == timeoutTask)
        {
            // cancel the read if timeout occurs
            cts.Cancel();
            throw new TimeoutException($"Read timed out after {timeoutMs} ms");
        }

        return await readTask; // completes normally
    }

    private static async Task WriteWithTimeout(
        Stream stream, byte[] buffer, int offset, int count, int timeoutMs)
    {
        using var cts = new CancellationTokenSource();
        var writeTask = stream.WriteAsync(buffer, offset, count, cts.Token);
        var timeoutTask = Task.Delay(timeoutMs);

        var completed = await Task.WhenAny(writeTask, timeoutTask);
        if (completed == timeoutTask)
        {
            // cancel the write if timeout occurs
            cts.Cancel();
            throw new TimeoutException($"Write timed out after {timeoutMs} ms");
        }

        await writeTask; // completes normally
    }


    private static async Task<string> ReadFrame(Stream stream)
    {
        var headerBuilder = new StringBuilder();

        while (true)
        {
            byte[] oneByte = new byte[1];

            int bytesRead = await ReadWithTimeout(
                stream, oneByte, 0, 1, _readTimeout);

            if (bytesRead == 0) return null!;

            char c = (char)oneByte[0];
            if (c == '!') break;

            if (!char.IsDigit(c))
                throw new InvalidDataException("Invalid frame header");

            headerBuilder.Append(c);
        }

        if (!int.TryParse(headerBuilder.ToString(), out int size) || size < 0)
            throw new InvalidDataException("Invalid frame size");

        var buffer = new byte[size];
        int read = 0;

        while (read < size)
        {
            int r = await ReadWithTimeout(
                stream, buffer, read, size - read, _readTimeout);

            if (r == 0)
                throw new EndOfStreamException();

            read += r;
        }

        return Encoding.UTF8.GetString(buffer);
    }

    private static async Task WriteFrame(Stream stream, string payload)
    {
        var data = Encoding.UTF8.GetBytes(payload);
        var header = Encoding.UTF8.GetBytes(data.Length.ToString() + "!");

        await WriteWithTimeout(
            stream, header, 0, header.Length, _writeTimeout);

        await WriteWithTimeout(
            stream, data, 0, data.Length, _writeTimeout);

        await stream.FlushAsync();
    }

    // -------------------------
    // PowerShell Execution
    // -------------------------

    private class Request
    {
        required public string Command { get; set; }
        public string[] Args { get; set; } = Array.Empty<string>();
    }

    private static async Task<string> ExecuteCommand(string requestJson, string user)
    {
        Console.WriteLine($"Received request JSON: {requestJson}");
        Request req;
        try
        {
            req = JsonSerializer.Deserialize<Request>(requestJson)
                ?? throw new Exception("Invalid request JSON");

            if (string.IsNullOrEmpty(req.Command))
                throw new Exception("Invalid request");
        }
        catch
        {
            return JsonSerializer.Serialize(new
            {
                CommandError = true,
                CommandErrorMessage = "Malformed request JSON"
            });
        }

        if (!_scriptMap.TryGetValue(req.Command, out string? scriptPath))
        {
            return JsonSerializer.Serialize(new
            {
                CommandError = true,
                CommandErrorMessage = $"Command '{req.Command}' not found"
            });
        }

        var fullPath = Path.Combine(_baseDir, "Scripts", scriptPath);
        if (!File.Exists(fullPath))
        {
            return JsonSerializer.Serialize(new
            {
                CommandError = true,
                CommandErrorMessage = $"Script file '{scriptPath}' missing"
            });
        }

        try
        {
            using var ps = PowerShell.Create();

            ps.AddCommand("Set-ExecutionPolicy")
            .AddParameter("Scope", "Process")
            .AddParameter("ExecutionPolicy", "Bypass")
            .AddParameter("Force")
            .Invoke();
            ps.Commands.Clear();

            ps.AddCommand(fullPath);
            ps.AddParameter("RequestingUser", user);
            if (req.Args.Length > 0)
                ps.AddParameter("CommandArgs", req.Args);

            ps.AddCommand("ConvertTo-Json").AddParameter("Depth", 5);

            var results = await Task.Run(() => ps.Invoke());

            if (ps.Streams.Error.Count > 0)
            {
                var errors = new List<string>();
                foreach (var e in ps.Streams.Error)
                    errors.Add(e.ToString());

                return JsonSerializer.Serialize(new
                {
                    CommandError = true,
                    CommandErrorMessage = string.Join("\n", errors)
                });
            }

            string scriptJson = results.Count > 0 ? results[0].ToString() : "{}";

            using var doc = JsonDocument.Parse(scriptJson);
            var jsonDict = new Dictionary<string, object>();
            foreach (var prop in doc.RootElement.EnumerateObject())
                jsonDict[prop.Name] = prop.Value.Clone();

            jsonDict["CommandError"] = false;
            jsonDict["CommandErrorMessage"] = "";

            return JsonSerializer.Serialize(jsonDict);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Server exception: {ex.Message}");
            return JsonSerializer.Serialize(new
            {
                CommandError = true,
                CommandErrorMessage = $"Server exception: {ex.Message}"
            });
        }
    }
}
