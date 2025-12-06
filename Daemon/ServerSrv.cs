// ServerSrv.cs
using System.ServiceProcess;

public class ServerService : ServiceBase
{
    public ServerService() => ServiceName = "ControlledAdminCommandService";

    protected override void OnStart(string[] args) => ServerCommon.Start();
    protected override void OnStop() => ServerCommon.Stop();

    public static void Main()
    {
        ServiceBase.Run(new ServerService());
    }
}
