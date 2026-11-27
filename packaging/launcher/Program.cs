using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

namespace QuSpace.QuMeter
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            try
            {
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);

                string appDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
                if (string.IsNullOrEmpty(appDir))
                    appDir = AppDomain.CurrentDomain.BaseDirectory;

                bool engine = false;
                string config = null;
                string progress = null;
                string trigger = "schedule";

                for (int i = 0; i < args.Length; i++)
                {
                    string a = args[i];
                    if (string.Equals(a, "--engine", StringComparison.OrdinalIgnoreCase) ||
                        string.Equals(a, "-engine", StringComparison.OrdinalIgnoreCase))
                    {
                        engine = true;
                    }
                    else if ((string.Equals(a, "--config", StringComparison.OrdinalIgnoreCase) ||
                              string.Equals(a, "-config", StringComparison.OrdinalIgnoreCase)) && i + 1 < args.Length)
                    {
                        config = args[++i];
                    }
                    else if ((string.Equals(a, "--progress", StringComparison.OrdinalIgnoreCase) ||
                              string.Equals(a, "-progress", StringComparison.OrdinalIgnoreCase)) && i + 1 < args.Length)
                    {
                        progress = args[++i];
                    }
                    else if ((string.Equals(a, "--trigger", StringComparison.OrdinalIgnoreCase) ||
                              string.Equals(a, "-trigger", StringComparison.OrdinalIgnoreCase)) && i + 1 < args.Length)
                    {
                        trigger = args[++i];
                    }
                }

                Log("start args=[" + string.Join(" ", args) + "] appDir=" + appDir + " cwd=" + Environment.CurrentDirectory);
                string script = Path.Combine(appDir, engine ? "QuMeterEngine.ps1" : "QuMeter.ps1");
                if (!File.Exists(script))
                {
                    MessageBox.Show("QuMeter script not found:\n" + script, "QuMeter", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return 1;
                }

                int rc = RunScript(appDir, script, engine, config, progress, trigger);
                Log("exit rc=" + rc);
                return rc;
            }
            catch (Exception ex)
            {
                Log("FATAL " + ex);
                try
                {
                    MessageBox.Show(ex.Message, "QuMeter", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                catch { }
                return 1;
            }
        }

        private static void Log(string msg)
        {
            try
            {
                string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "QuMeter");
                Directory.CreateDirectory(dir);
                File.AppendAllText(Path.Combine(dir, "startup.log"), DateTime.Now.ToString("s") + " " + msg + Environment.NewLine);
            }
            catch { }
        }

        private static int RunScript(string appDir, string scriptPath, bool engine, string config, string progress, string trigger)
        {
            // Host Windows PowerShell 5.1 in-process on this STA thread (required for WinForms).
            // The in-process host otherwise obeys the machine's execution policy (Restricted by default),
            // which blocks the unsigned package scripts and made the app exit silently. Bypass applies to this process only.
            InitialSessionState iss = InitialSessionState.CreateDefault();
            iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
            using (Runspace rs = RunspaceFactory.CreateRunspace(iss))
            {
            rs.ApartmentState = ApartmentState.STA;
            rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
            rs.Open();
            using (PowerShell ps = PowerShell.Create())
            {
            ps.Runspace = rs;
                ps.Runspace.SessionStateProxy.Path.SetLocation(appDir);

                if (engine)
                {
                    var sb = new System.Text.StringBuilder();
                    sb.Append("& '").Append(EscapePsSingle(scriptPath)).Append("'");
                    if (!string.IsNullOrEmpty(config))
                        sb.Append(" -ConfigPath '").Append(EscapePsSingle(config)).Append("'");
                    if (!string.IsNullOrEmpty(progress))
                        sb.Append(" -ProgressFile '").Append(EscapePsSingle(progress)).Append("'");
                    if (!string.IsNullOrEmpty(trigger))
                        sb.Append(" -Trigger '").Append(EscapePsSingle(trigger)).Append("'");
                    ps.AddScript(sb.ToString());
                }
                else
                {
                    ps.AddScript("& '" + EscapePsSingle(scriptPath) + "'");
                }

                try
                {
                    ps.Invoke();
                }
                catch (ExitException exitEx)
                {
                    return GetExitCode(exitEx);
                }
                catch (RuntimeException rex)
                {
                    ExitException nested = FindExitException(rex);
                    if (nested != null) return GetExitCode(nested);
                    if (engine)
                    {
                        Console.Error.WriteLine(rex.Message);
                        return 1;
                    }
                    Log("RuntimeException " + rex);
                    MessageBox.Show(rex.Message, "QuMeter", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return 1;
                }

                foreach (var err in ps.Streams.Error) Log("PS error: " + err);
                if (!engine && ps.HadErrors && ps.Streams.Error.Count > 0)
                {
                    try { MessageBox.Show("QuMeter could not start:\n\n" + ps.Streams.Error[0], "QuMeter", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { }
                    return 1;
                }
                if (ps.HadErrors)
                {
                    foreach (var err in ps.Streams.Error)
                    {
                        ExitException nested = FindExitException(err.Exception);
                        if (nested != null) return GetExitCode(nested);
                    }
                }

                // PS 5.1: `exit N` inside an &-invoked script sets $LASTEXITCODE and HadErrors
                // without throwing ExitException or writing the error stream.
                if (engine)
                {
                    int? last = TryGetLastExitCode(ps);
                    if (last.HasValue) return last.Value;
                }

                if (ps.HadErrors && engine)
                {
                    foreach (var err in ps.Streams.Error)
                        Console.Error.WriteLine(err.ToString());
                    return 1;
                }

                return Environment.ExitCode != 0 ? Environment.ExitCode : 0;
            }
            }
        }

        private static int? TryGetLastExitCode(PowerShell ps)
        {
            try
            {
                PSVariable v = ps.Runspace.SessionStateProxy.PSVariable.Get("LASTEXITCODE");
                if (v == null || v.Value == null) return null;
                if (v.Value is int) return (int)v.Value;
                int parsed;
                if (int.TryParse(Convert.ToString(v.Value), out parsed)) return parsed;
            }
            catch { }
            return null;
        }

        private static string EscapePsSingle(string s)
        {
            if (s == null) return string.Empty;
            return s.Replace("'", "''");
        }

        private static ExitException FindExitException(Exception ex)
        {
            while (ex != null)
            {
                ExitException ee = ex as ExitException;
                if (ee != null) return ee;
                ex = ex.InnerException;
            }
            return null;
        }

        private static int GetExitCode(ExitException ex)
        {
            try
            {
                // Windows PowerShell 5.1 stores the exit code in ExitException.Argument.
                object arg = ex.Argument;
                if (arg is int) return (int)arg;
                if (arg != null)
                {
                    int parsed;
                    if (int.TryParse(Convert.ToString(arg), out parsed)) return parsed;
                }

                PropertyInfo pi = typeof(ExitException).GetProperty("ExitCode", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
                if (pi != null)
                {
                    object v = pi.GetValue(ex, null);
                    if (v is int) return (int)v;
                }
                FieldInfo fi = typeof(ExitException).GetField("exitCode", BindingFlags.Instance | BindingFlags.NonPublic);
                if (fi != null)
                {
                    object v = fi.GetValue(ex);
                    if (v is int) return (int)v;
                }
            }
            catch { }
            return Environment.ExitCode != 0 ? Environment.ExitCode : 0;
        }
    }
}
