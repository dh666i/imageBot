using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace ImageBotLauncher
{
    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            string appDir = AppDomain.CurrentDomain.BaseDirectory;
            string exitEventName = BuildInstanceName("ImageBotLauncherExit", appDir);
            if (HasArgument(args, "--exit"))
            {
                SignalExistingInstance(exitEventName);
                return;
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            bool created;
            using (Mutex mutex = new Mutex(true, BuildMutexName(appDir), out created))
            {
                if (!created)
                {
                    LauncherConfig existing = LauncherConfig.Load(appDir);
                    if (Health.IsReady(existing.Url, 1500))
                    {
                        if (ShouldOpenBrowser()) Browser.Open(existing.Url);
                    }
                    else
                    {
                        MessageBox.Show("ImageBot 正在启动，请稍等几秒后再试。", "ImageBot", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    }
                    return;
                }

                bool eventCreated;
                using (EventWaitHandle exitSignal = new EventWaitHandle(false, EventResetMode.AutoReset, exitEventName, out eventCreated))
                {
                    Application.Run(new TrayContext(appDir, exitSignal));
                }
            }
        }

        private static string BuildMutexName(string appDir)
        {
            return BuildInstanceName("ImageBotLauncher", appDir);
        }

        private static string BuildInstanceName(string prefix, string appDir)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(Path.GetFullPath(appDir).ToLowerInvariant());
            using (SHA256 sha = SHA256.Create())
            {
                string hash = BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").Substring(0, 20);
                return "Local\\" + prefix + "-" + hash;
            }
        }

        private static bool HasArgument(string[] args, string expected)
        {
            if (args == null) return false;
            foreach (string arg in args)
            {
                if (String.Equals(arg, expected, StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }

        private static void SignalExistingInstance(string eventName)
        {
            try
            {
                using (EventWaitHandle signal = EventWaitHandle.OpenExisting(eventName)) signal.Set();
            }
            catch (WaitHandleCannotBeOpenedException) { }
        }

        private static bool ShouldOpenBrowser()
        {
            return !String.Equals(Environment.GetEnvironmentVariable("IMAGEBOT_LAUNCHER_NO_BROWSER"), "1", StringComparison.OrdinalIgnoreCase);
        }
    }

    internal sealed class TrayContext : ApplicationContext
    {
        private readonly string appDir;
        private readonly NotifyIcon tray;
        private readonly System.Windows.Forms.Timer startupTimer;
        private readonly System.Windows.Forms.Timer controlTimer;
        private readonly EventWaitHandle exitSignal;
        private LauncherConfig config;
        private Process serverProcess;
        private int startupChecks;
        private bool exiting;

        public TrayContext(string appDir, EventWaitHandle exitSignal)
        {
            this.appDir = appDir;
            this.exitSignal = exitSignal;
            this.config = LauncherConfig.Load(appDir);

            ContextMenuStrip menu = new ContextMenuStrip();
            menu.Items.Add("打开 ImageBot", null, delegate { OpenBrowser(); });
            menu.Items.Add("重新启动服务", null, delegate { RestartServer(); });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("退出 ImageBot", null, delegate { ExitImageBot(); });

            tray = new NotifyIcon();
            tray.Icon = SystemIcons.Application;
            tray.Text = "ImageBot 图片生成工具";
            tray.ContextMenuStrip = menu;
            tray.Visible = true;
            tray.DoubleClick += delegate { OpenBrowser(); };

            startupTimer = new System.Windows.Forms.Timer();
            startupTimer.Interval = 350;
            startupTimer.Tick += CheckStartup;

            controlTimer = new System.Windows.Forms.Timer();
            controlTimer.Interval = 250;
            controlTimer.Tick += CheckControlSignal;
            controlTimer.Start();

            if (Health.IsReady(config.Url, 1000))
            {
                ShowReady();
            }
            else
            {
                StartServer();
            }
        }

        private void CheckControlSignal(object sender, EventArgs e)
        {
            if (exitSignal.WaitOne(0)) ExitImageBot();
        }

        private void StartServer()
        {
            try
            {
                config = LauncherConfig.Load(appDir);
                if (!File.Exists(config.ScriptPath))
                {
                    Fail("程序文件不完整，请重新解压后再启动。\n\n缺少：" + Path.GetFileName(config.ScriptPath));
                    return;
                }

                if (!File.Exists(config.ConfigPath))
                {
                    if (!File.Exists(config.ExampleConfigPath))
                    {
                        Fail("程序文件不完整，请重新下载。\n\n缺少：config.example.ini");
                        return;
                    }
                    File.Copy(config.ExampleConfigPath, config.ConfigPath, false);
                    config = LauncherConfig.Load(appDir);
                }

                if (!PortIsAvailable(config.Port) && !Health.IsReady(config.Url, 1000))
                {
                    Fail("端口 " + config.Port + " 已被其他程序占用。\n\n请关闭占用端口的程序，或修改 config.ini 中的 IMAGE_WEBUI_PORT。");
                    return;
                }

                ProcessStartInfo start = new ProcessStartInfo();
                start.FileName = config.PowerShellPath;
                start.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File " + Quote(config.ScriptPath) + " -ConfigPath " + Quote(config.ConfigPath);
                start.WorkingDirectory = appDir;
                start.UseShellExecute = false;
                start.CreateNoWindow = true;
                start.WindowStyle = ProcessWindowStyle.Hidden;
                start.EnvironmentVariables["IMAGEBOT_LAUNCHER"] = "1";
                serverProcess = Process.Start(start);

                startupChecks = 0;
                tray.Text = "ImageBot 正在启动";
                tray.ShowBalloonTip(1500, "ImageBot", "正在启动，请稍候...", ToolTipIcon.Info);
                startupTimer.Start();
            }
            catch (Exception ex)
            {
                Fail("ImageBot 启动失败。\n\n" + FriendlyMessage(ex));
            }
        }

        private void CheckStartup(object sender, EventArgs e)
        {
            startupChecks++;
            if (Health.IsReady(config.Url, 700))
            {
                startupTimer.Stop();
                ShowReady();
                return;
            }

            if (serverProcess != null && serverProcess.HasExited)
            {
                startupTimer.Stop();
                Fail("ImageBot 没有成功启动。\n\n请确认程序已完整解压，并检查杀毒软件是否拦截了 PowerShell。\n退出代码：" + serverProcess.ExitCode);
                return;
            }

            if (startupChecks >= 85)
            {
                startupTimer.Stop();
                StopServer();
                Fail("ImageBot 启动超时。\n\n请检查端口设置、防火墙和程序文件是否完整。", false);
            }
        }

        private void ShowReady()
        {
            tray.Text = "ImageBot 已启动";
            tray.ShowBalloonTip(1800, "ImageBot 已启动", "双击托盘图标可以重新打开页面。", ToolTipIcon.Info);
            if (!String.Equals(Environment.GetEnvironmentVariable("IMAGEBOT_LAUNCHER_NO_BROWSER"), "1", StringComparison.OrdinalIgnoreCase)) OpenBrowser();
        }

        private void OpenBrowser()
        {
            if (!Health.IsReady(config.Url, 1200))
            {
                if (serverProcess == null || serverProcess.HasExited)
                {
                    StartServer();
                    return;
                }
                MessageBox.Show("ImageBot 仍在启动，请稍后再试。", "ImageBot", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            Browser.Open(config.Url);
        }

        private void RestartServer()
        {
            startupTimer.Stop();
            StopServer();
            Thread.Sleep(350);
            StartServer();
        }

        private void StopServer()
        {
            Health.RequestShutdown(config.Url);
            if (serverProcess != null)
            {
                try
                {
                    if (!serverProcess.WaitForExit(2500)) serverProcess.Kill();
                }
                catch { }
                serverProcess = null;
            }
        }

        private void ExitImageBot()
        {
            if (exiting) return;
            exiting = true;
            startupTimer.Stop();
            controlTimer.Stop();
            StopServer();
            tray.Visible = false;
            tray.Dispose();
            ExitThread();
        }

        private void Fail(string message)
        {
            Fail(message, true);
        }

        private void Fail(string message, bool stopServer)
        {
            if (stopServer) StopServer();
            controlTimer.Stop();
            MessageBox.Show(message, "ImageBot", MessageBoxButtons.OK, MessageBoxIcon.Error);
            tray.Visible = false;
            tray.Dispose();
            ExitThread();
        }

        protected override void ExitThreadCore()
        {
            if (!exiting)
            {
                exiting = true;
                startupTimer.Stop();
                controlTimer.Stop();
                StopServer();
                tray.Visible = false;
                tray.Dispose();
            }
            base.ExitThreadCore();
        }

        private static bool PortIsAvailable(int port)
        {
            TcpListener listener = null;
            try
            {
                listener = new TcpListener(IPAddress.Loopback, port);
                listener.Start();
                return true;
            }
            catch
            {
                return false;
            }
            finally
            {
                if (listener != null) listener.Stop();
            }
        }

        private static string Quote(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        private static string FriendlyMessage(Exception ex)
        {
            if (ex is UnauthorizedAccessException) return "没有文件访问权限，请把程序解压到桌面或文档目录后再试。";
            return ex.Message;
        }
    }

    internal sealed class LauncherConfig
    {
        public string AppDir;
        public string ConfigPath;
        public string ExampleConfigPath;
        public string ScriptPath;
        public string PowerShellPath;
        public string Url;
        public int Port;

        public static LauncherConfig Load(string appDir)
        {
            LauncherConfig config = new LauncherConfig();
            config.AppDir = appDir;
            config.ConfigPath = Path.Combine(appDir, "config.ini");
            config.ExampleConfigPath = Path.Combine(appDir, "config.example.ini");
            config.ScriptPath = Path.Combine(appDir, "openai_images_webui_no_python_config.ps1");
            config.PowerShellPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
            if (!File.Exists(config.PowerShellPath)) config.PowerShellPath = "powershell.exe";

            Dictionary<string, string> values = ReadIni(File.Exists(config.ConfigPath) ? config.ConfigPath : config.ExampleConfigPath);
            string host = Get(values, "IMAGE_WEBUI_HOST", "127.0.0.1");
            if (host == "0.0.0.0" || host == "*" || host.Equals("localhost", StringComparison.OrdinalIgnoreCase)) host = "127.0.0.1";
            int port;
            if (!Int32.TryParse(Get(values, "IMAGE_WEBUI_PORT", "7861"), out port) || port < 1 || port > 65535) port = 7861;
            config.Port = port;
            config.Url = "http://" + host + ":" + port;
            return config;
        }

        private static Dictionary<string, string> ReadIni(string path)
        {
            Dictionary<string, string> values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (String.IsNullOrEmpty(path) || !File.Exists(path)) return values;
            foreach (string source in File.ReadAllLines(path, Encoding.UTF8))
            {
                string line = source.Trim();
                if (line.Length == 0 || line.StartsWith("#") || line.StartsWith(";")) continue;
                int index = line.IndexOf('=');
                if (index <= 0) continue;
                string key = line.Substring(0, index).Trim();
                string value = line.Substring(index + 1).Trim().Trim('"', '\'');
                values[key] = value;
            }
            return values;
        }

        private static string Get(Dictionary<string, string> values, string key, string fallback)
        {
            string value;
            return values.TryGetValue(key, out value) && !String.IsNullOrWhiteSpace(value) ? value : fallback;
        }
    }

    internal static class Health
    {
        public static bool IsReady(string baseUrl, int timeoutMs)
        {
            try
            {
                HttpWebRequest request = (HttpWebRequest)WebRequest.Create(baseUrl.TrimEnd('/') + "/api/health");
                request.Method = "GET";
                request.Timeout = timeoutMs;
                request.ReadWriteTimeout = timeoutMs;
                request.KeepAlive = false;
                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                {
                    return response.StatusCode == HttpStatusCode.OK;
                }
            }
            catch
            {
                return false;
            }
        }

        public static void RequestShutdown(string baseUrl)
        {
            try
            {
                byte[] body = Encoding.UTF8.GetBytes("{}");
                HttpWebRequest request = (HttpWebRequest)WebRequest.Create(baseUrl.TrimEnd('/') + "/api/shutdown");
                request.Method = "POST";
                request.ContentType = "application/json";
                request.ContentLength = body.Length;
                request.Timeout = 1200;
                request.ReadWriteTimeout = 1200;
                request.KeepAlive = false;
                using (Stream stream = request.GetRequestStream()) stream.Write(body, 0, body.Length);
                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse()) { }
            }
            catch { }
        }
    }

    internal static class Browser
    {
        public static void Open(string url)
        {
            try
            {
                ProcessStartInfo info = new ProcessStartInfo(url);
                info.UseShellExecute = true;
                Process.Start(info);
            }
            catch (Exception ex)
            {
                MessageBox.Show("无法自动打开浏览器。请手动打开：\n\n" + url + "\n\n" + ex.Message, "ImageBot", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
        }
    }
}
