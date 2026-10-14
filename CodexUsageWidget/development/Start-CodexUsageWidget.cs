using System;
using System.Diagnostics;
using System.IO;

internal static class StartCodexUsageWidget
{
    [STAThread]
    private static void Main()
    {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(root, "CodexUsageWidget.ps1");
        if (!File.Exists(script))
        {
            script = Path.Combine(root, "app", "CodexUsageWidget.ps1");
        }
        if (!File.Exists(script))
        {
            System.Windows.Forms.MessageBox.Show(
                "CodexUsageWidget.ps1 was not found next to this launcher.",
                "Codex Usage Widget");
            return;
        }

        var info = new ProcessStartInfo();
        info.FileName = "powershell.exe";
        info.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + script + "\"";
        info.UseShellExecute = false;
        info.CreateNoWindow = true;
        info.WindowStyle = ProcessWindowStyle.Hidden;
        Process.Start(info);
    }
}
