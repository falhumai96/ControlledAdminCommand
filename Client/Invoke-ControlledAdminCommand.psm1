function Invoke-ControlledAdminCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [string[]]$CommandArgs = @(),

        [int]$Timeout = 10000,       # milliseconds

        [int]$ReadTimeout = 10000,   # milliseconds

        [int]$WriteTimeout = 10000   # milliseconds
    )

    begin {
        $ErrorActionPreference = "Stop"

        # private constant
        $PipeName = "ControlledAdminCommand"

        # -------------------------
        # Helpers
        # -------------------------

        function Read-WithTimeout {
            param(
                [System.IO.Pipes.NamedPipeClientStream]$Stream,
                [int]$Count,
                [int]$TimeoutMs
            )

            $buffer = New-Object byte[] $Count

            # Cancellation token for this read
            $cts = New-Object System.Threading.CancellationTokenSource

            try {
                $readTask = $Stream.ReadAsync($buffer, 0, $Count, $cts.Token)
                $timeoutTask = [System.Threading.Tasks.Task]::Delay($TimeoutMs)

                $completed = [System.Threading.Tasks.Task]::WhenAny($readTask, $timeoutTask).Result

                if ($completed -eq $timeoutTask) {
                    # Cancel the read
                    $cts.Cancel()
                    throw "Read timed out after $TimeoutMs ms"
                }

                return , ($buffer, $readTask.Result)
            }
            finally {
                $cts.Dispose()
            }
        }

        function Write-WithTimeout {
            param(
                [System.IO.Pipes.NamedPipeClientStream]$Stream,
                [byte[]]$Buffer,
                [int]$TimeoutMs
            )

            # Cancellation token for this write
            $cts = New-Object System.Threading.CancellationTokenSource

            try {
                $writeTask = $Stream.WriteAsync($Buffer, 0, $Buffer.Length, $cts.Token)
                $timeoutTask = [System.Threading.Tasks.Task]::Delay($TimeoutMs)

                $completed = [System.Threading.Tasks.Task]::WhenAny($writeTask, $timeoutTask).Result

                if ($completed -eq $timeoutTask) {
                    # Cancel the write
                    $cts.Cancel()
                    throw "Write timed out after $TimeoutMs ms"
                }

                $writeTask.Wait()
            }
            finally {
                $cts.Dispose()
            }
        }

        function Send-Frame {
            param(
                [System.IO.Pipes.NamedPipeClientStream]$Stream,
                [string]$Payload
            )

            $data = [System.Text.Encoding]::UTF8.GetBytes($Payload)
            $header = [System.Text.Encoding]::UTF8.GetBytes($data.Length.ToString() + "!")

            Write-WithTimeout -Stream $Stream -Buffer $header -TimeoutMs $WriteTimeout
            Write-WithTimeout -Stream $Stream -Buffer $data   -TimeoutMs $WriteTimeout

            $Stream.Flush()
        }

        function Receive-Frame {
            param(
                [System.IO.Pipes.NamedPipeClientStream]$Stream
            )

            # Read header until '!'
            $header = ""
            while ($true) {
                $pair = Read-WithTimeout -Stream $Stream -Count 1 -TimeoutMs $ReadTimeout
                $buffer = $pair[0]
                $bytesRead = $pair[1]

                if ($bytesRead -eq 0) { throw "Stream closed" }

                $c = [char]$buffer[0]
                if ($c -eq '!') { break }
                if ($c -notmatch '\d') { throw "Invalid frame header" }
                $header += $c
            }

            $size = 0
            if (-not [int]::TryParse($header, [ref]$size) -or $size -lt 0) {
                throw "Invalid frame size"
            }

            # Read payload
            $buffer = New-Object byte[] $size
            $read = 0
            while ($read -lt $size) {
                $remaining = $size - $read
                $pair = Read-WithTimeout -Stream $Stream -Count $remaining -TimeoutMs $ReadTimeout
                $chunk = $pair[0]
                $bytesRead = $pair[1]

                if ($bytesRead -eq 0) { throw "Stream ended prematurely" }

                [Array]::Copy($chunk, 0, $buffer, $read, $bytesRead)
                $read += $bytesRead
            }

            return [System.Text.Encoding]::UTF8.GetString($buffer)
        }
    }

    process {
        # Build request JSON
        $requestObj = @{
            Command = $Command
            Args    = $CommandArgs
        }

        $requestJson = ($requestObj | ConvertTo-Json -Compress)

        try {
            # Connect to pipe
            $client = New-Object System.IO.Pipes.NamedPipeClientStream(
                ".", $PipeName,
                [System.IO.Pipes.PipeDirection]::InOut,
                [System.IO.Pipes.PipeOptions]::None
            )

            $client.Connect($Timeout)

            Send-Frame   -Stream $client -Payload $requestJson
            $responseJson = Receive-Frame -Stream $client
            $responseObj = $responseJson | ConvertFrom-Json

            return $responseObj
        }
        catch {
            throw "$($_.Exception.Message)"
        }
        finally {
            $client.Dispose()
        }
    }
}
