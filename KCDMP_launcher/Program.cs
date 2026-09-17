// See https://aka.ms/new-console-template for more information
using Photino.Blazor;
using Microsoft.Extensions.DependencyInjection;
using KCDMP_launcher;
using System.IO;
using System;
using KCDMP_launcher.Services;
using Microsoft.Extensions.Logging;
using Serilog;
using KCDMP_launcher.Components.Shared;

class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        Log.Logger = new LoggerConfiguration()
            .MinimumLevel.Debug()
            // WO-39 (item J): Blazor's per-component render/init Debug lines
            // were ~80% of both real testers' log files -- every state change
            // logs a full render pass over the modal tree. The launcher's own
            // Debug logging stays; the framework's render narration goes.
            .MinimumLevel.Override("Microsoft.AspNetCore.Components", Serilog.Events.LogEventLevel.Information)
            .WriteTo.File(Path.Combine(Globals.AppFolder, "app.log"),
                rollingInterval: RollingInterval.Day,
                retainedFileCountLimit: 10)
            .CreateLogger();

        try
        {
            Log.Information("=== Start KCD2 MP Launcher ===");

            var appBuilder = PhotinoBlazorAppBuilder.CreateDefault(args);

            var baseDir = AppDomain.CurrentDomain.BaseDirectory;
            var wwwrootPath = Path.Combine(baseDir, "wwwroot");

            if (Directory.Exists(wwwrootPath))
            {
                appBuilder.Services.AddSingleton<Microsoft.Extensions.FileProviders.IFileProvider>(
                    new Microsoft.Extensions.FileProviders.PhysicalFileProvider(wwwrootPath));
            }

            appBuilder.Services.AddLogging(loggingBuilder =>
            {
                loggingBuilder.ClearProviders();
                loggingBuilder.AddSerilog(dispose: true);
            });

            appBuilder.Services.AddSingleton<KCDMP_launcher.Services.UiService>();
            appBuilder.Services.AddSingleton<KCDMP_launcher.Services.NetService>();
            appBuilder.RootComponents.Add<App>("#app");

            var app = appBuilder.Build();

            app.MainWindow
                .SetTitle("KCD2 MP Launcher")
                .SetSize(1600, 900)
                .SetMaximized(true)
                .SetResizable(true)
                .SetContextMenuEnabled(false)
                .Center();

            // WO-50: <ApplicationIcon> in the csproj only sets the .exe's own
            // file icon (Explorer, shortcuts, taskbar when not running).
            // Photino's actual window -- title bar, and the taskbar icon
            // while it's running -- is a separate runtime setting.
            //
            // WO-98 Phase 0: this used to pass the bare relative "app.ico".
            // Photino's IconFile setter does probe AppContext.BaseDirectory
            // when the relative path is not found, but it then STORES the
            // relative string, and the later startup-parameter validation
            // re-checks File.Exists against the process working directory
            // and throws "WindowIconFile: app.ico cannot be found" (observed
            // on a tester's machine in 0.22.4, code-verified against
            // Photino.NET's PhotinoWindow IconFile setter). So the launcher
            // hard-crashed whenever it was started from any directory other
            // than its own. Resolve the path ourselves and never let a missing
            // icon take the whole launcher down -- an icon is decoration.
            var iconPath = Path.Combine(AppContext.BaseDirectory, "app.ico");
            if (File.Exists(iconPath))
                app.MainWindow.SetIconFile(iconPath);
            else
                Log.Warning("app.ico not found beside the launcher ({IconPath}); window icon skipped", iconPath);

            AppDomain.CurrentDomain.UnhandledException += (sender, error) =>
            {
                var ex = error.ExceptionObject as Exception;
                Log.Fatal(ex, "Unexpected expection!");
                app.MainWindow.ShowMessage("Fatal Error", error.ExceptionObject.ToString());
            };

            app.Run();

            // WO-39 (item I): the launcher never logged anything on a normal
            // exit, so WO-38's "two silent sub-second crashes" (33 boot
            // lines, then nothing) were indistinguishable from a tester
            // simply closing the window fast -- which the timeline suggests
            // (four boots in 42 s while fighting the dead master server).
            // With this marker, a future boot that ends without it IS crash
            // evidence, not a guess.
            Log.Information("=== Launcher exiting (clean) ===");
        }
        catch (Exception ex)
        {
            Log.Fatal(ex, "App encountered an error while launching!");
        }
        finally
        {
            Log.CloseAndFlush();
        }
    }
}