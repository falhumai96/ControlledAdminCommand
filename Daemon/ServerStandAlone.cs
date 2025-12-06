// ServerStandAlone.cs
using System;
using System.Threading;

class Program
{
    static int Main()
    {
        // Make Ctrl-C behave as a normal key instead of a control signal
        Console.TreatControlCAsInput = true;

        Console.WriteLine("Press CTRL-C to stop.");

        bool stopped = false;

        // Start your server
        ServerCommon.Start();

        while (!stopped)
        {
            // Check keyboard input without blocking
            if (Console.KeyAvailable)
            {
                var key = Console.ReadKey(intercept: true);

                // Detect Ctrl-C
                if (key.Key == ConsoleKey.C && key.Modifiers == ConsoleModifiers.Control)
                {
                    stopped = true;
                    break;
                }
            }

            Thread.Sleep(100); // non-busy wait loop
        }

        // Stop your server cleanly
        ServerCommon.Stop();

        return 0;
    }
}
