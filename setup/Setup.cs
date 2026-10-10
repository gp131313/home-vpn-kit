// Setup.cs - single-file installer of home-vpn-kit for people who do not want to see a console.
// The exe carries install.ps1, uninstall.ps1 and the vpn\ scripts as resources, unpacks them into
// <InstallDir>\setup (not %TEMP%: antivirus blocks scripts started from there) and runs install.ps1
// with -NoPrompt. The VPN password goes to install.ps1 through stdin, never through the command line.
// The manifest (app.manifest) asks for administrator rights once, at start. Build: build.ps1.
//   HomeVpnKit-Setup.exe          wizard: Next -> settings -> Install -> Finish
//   HomeVpnKit-Setup-Silent.exe   no windows at all (same as /silent); settings from config.json next to
//                                 the exe or from the previous installation, password from HVK_PASSWORD or
//                                 the saved one; /dir=<folder> /skiptray /server= /user= /probe= /nets=
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Management;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: AssemblyTitle("Home VPN Kit Setup")]
[assembly: AssemblyProduct("Home VPN Kit")]
[assembly: AssemblyVersion("1.1.2.0")]
[assembly: AssemblyFileVersion("1.1.2.0")]

public class KitSettings
{
    public string Server = "", User = "", ProbeHost = "192.168.1.1", Nets = "";
    public bool Tray = true;
}

public static class Setup
{
    public const string Title = "Home VPN Kit";
    public const string Version = "1.1.2";
    public static bool Ru = System.Globalization.CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ru";
    public static string T(string ru, string en) { return Ru ? ru : en; }

    public static string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "HomeVpnKit");
    public static string SetupDir { get { return Path.Combine(Dir, "setup"); } }
    public static string LogFile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"HomeVpnKit\setup.log");
    public static bool SkipTray;
    static readonly string[] Resources = { "install.ps1", "uninstall.ps1", "Connect-Vpn.ps1", "Disconnect-Vpn.ps1", "Resume-Vpn.ps1" };

    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

    [STAThread]
    static int Main(string[] args)
    {
        bool silent = Path.GetFileNameWithoutExtension(Application.ExecutablePath).IndexOf("silent", StringComparison.OrdinalIgnoreCase) >= 0;
        KitSettings cli = new KitSettings(); bool cliAny = false;
        foreach (string a in args)
        {
            string s = a.TrimStart('/', '-');
            string k = s.ToLowerInvariant(), v = "";
            int eq = s.IndexOf('='); if (eq > 0) { k = s.Substring(0, eq).ToLowerInvariant(); v = s.Substring(eq + 1).Trim('"'); }
            if (k == "silent" || k == "verysilent" || k == "quiet" || k == "s" || k == "q") silent = true;
            else if (k == "skiptray") SkipTray = true;
            else if (k == "dir" && v.Length > 0) Dir = Path.GetFullPath(v).TrimEnd('\\');
            else if (k == "server") { cli.Server = v; cliAny = true; }
            else if (k == "user") { cli.User = v; cliAny = true; }
            else if (k == "probe") { cli.ProbeHost = v; cliAny = true; }
            else if (k == "nets") { cli.Nets = v; cliAny = true; }
        }
        if (silent)
        {
            try
            {
                KitSettings s = LoadSettings();
                if (cliAny) { if (cli.Server != "") s.Server = cli.Server; if (cli.User != "") s.User = cli.User; if (cli.ProbeHost != "") s.ProbeHost = cli.ProbeHost; if (cli.Nets != "") s.Nets = cli.Nets; }
                string pw = Environment.GetEnvironmentVariable("HVK_PASSWORD") ?? "";
                if (s.Server == "" || s.User == "") { Log("silent: server or user not set (config.json next to the exe or /server= /user=)"); return 2; }
                if (pw == "" && !CredExists) { Log("silent: no password (HVK_PASSWORD) and none saved"); return 2; }
                return RunInstall(s, pw, delegate(string line) { Log(line); });
            }
            catch (Exception ex) { Log("silent: " + ex.Message); return 1; }
        }
        SetProcessDPIAware();
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        string why = WrongAccount();
        if (why != null) { MessageBox.Show(why, Title, MessageBoxButtons.OK, MessageBoxIcon.Error); return 3; }
        Wizard w = new Wizard();
        Application.Run(w);
        return w.ExitCode;
    }

    public static bool CredExists { get { return File.Exists(Path.Combine(Dir, "cred.dat")); } }

    // The UAC prompt may have been answered with another administrator's password: then we run as that
    // account, and the password (DPAPI) and the tray indicator would be bound to the wrong user.
    static string WrongAccount()
    {
        try
        {
            string me = Environment.UserName;
            using (ManagementObjectSearcher q = new ManagementObjectSearcher("SELECT ProcessId FROM Win32_Process WHERE Name='explorer.exe'"))
            foreach (ManagementObject p in q.Get())
            {
                string[] owner = new string[2];
                p.InvokeMethod("GetOwner", owner);
                if (owner[0] == null) continue;
                if (string.Equals(owner[0], me, StringComparison.OrdinalIgnoreCase)) return null;
                return T("Вы вошли в Windows как " + owner[0] + ", а права администратора получены от учётной записи " + me + ".\n\n"
                       + "Пароль VPN и индикатор привязываются к учётной записи, поэтому войдите в Windows под учётной записью администратора, "
                       + "для которой ставите VPN, и запустите установку ещё раз.",
                         "You are signed in to Windows as " + owner[0] + ", but the administrator rights came from the account " + me + ".\n\n"
                       + "The VPN password and the tray indicator are bound to the account, so sign in to Windows with the administrator account "
                       + "that needs the VPN and run Setup again.");
            }
        }
        catch { }
        return null;
    }

    // settings of the previous installation (config.json in Dir), then config.json next to the exe on top
    public static KitSettings LoadSettings()
    {
        KitSettings s = new KitSettings();
        foreach (string f in new[] { Path.Combine(Dir, "config.json"), Path.Combine(Path.GetDirectoryName(Application.ExecutablePath), "config.json") })
        {
            if (!File.Exists(f)) continue;
            try
            {
                Dictionary<string, object> d = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(f));
                object v;
                if (d.TryGetValue("Server", out v) && v != null) s.Server = v.ToString();
                if (d.TryGetValue("User", out v) && v != null) s.User = v.ToString();
                if (d.TryGetValue("ProbeHost", out v) && v != null) s.ProbeHost = v.ToString();
                if (d.TryGetValue("HomeNetworks", out v) && v is System.Collections.IEnumerable && !(v is string))
                {
                    List<string> l = new List<string>();
                    foreach (object o in (System.Collections.IEnumerable)v) if (o != null) l.Add(o.ToString());
                    s.Nets = string.Join(", ", l.ToArray());
                }
            }
            catch { }
        }
        return s;
    }

    // names of the networks the computer is connected to right now (Network List Manager);
    // a network that lives on the OpenConnect (Wintun) adapter is the tunnel itself and is left out
    public static List<string> ConnectedNetworks(string server)
    {
        List<string> names = new List<string>();
        try
        {
            // the tunnel's network profile is named after its adapter ("<server>", "<server> 2", ...)
            List<string> tunnelNames = new List<string>();
            foreach (System.Net.NetworkInformation.NetworkInterface ni in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
                if (ni.Description.IndexOf("OpenConnect", StringComparison.OrdinalIgnoreCase) >= 0 || ni.Description.IndexOf("Wintun", StringComparison.OrdinalIgnoreCase) >= 0)
                    tunnelNames.Add(ni.Name);
            if (server != "") tunnelNames.Add(server);
            Type t = Type.GetTypeFromCLSID(new Guid("DCB00C01-570F-4A9B-8D69-199FDBA5723B"));
            dynamic nlm = Activator.CreateInstance(t);
            foreach (dynamic n in nlm.GetNetworks(1))   // NLM_ENUM_NETWORK_CONNECTED
            {
                string name = (string)n.GetName();
                if (string.IsNullOrEmpty(name)) continue;
                bool tunnel = false;
                foreach (string tn in tunnelNames) if (tn != "" && name.StartsWith(tn, StringComparison.OrdinalIgnoreCase)) tunnel = true;
                if (tunnel) continue;
                if (!names.Contains(name)) names.Add(name);
            }
        }
        catch { }
        return names;
    }

    public static void Log(string line)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LogFile));
            File.AppendAllText(LogFile, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + line + "\r\n", Encoding.UTF8);
        }
        catch { }
    }

    static string Q(string v) { return "\"" + v.Replace("\"", "") + "\""; }

    // unpack the scripts and run install.ps1; every output line goes to onLine; returns its exit code
    public static int RunInstall(KitSettings s, string password, Action<string> onLine)
    {
        Directory.CreateDirectory(SetupDir);
        Assembly asm = Assembly.GetExecutingAssembly();
        foreach (string name in Resources)
            using (Stream src = asm.GetManifestResourceStream(name))
            using (FileStream dst = File.Create(Path.Combine(SetupDir, name)))
                src.CopyTo(dst);

        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\WindowsPowerShell\v1.0\powershell.exe");
        string nets = s.Nets.Trim();
        string args = "-NoProfile -ExecutionPolicy Bypass -File " + Q(Path.Combine(SetupDir, "install.ps1"))
                    + " -NoPrompt -PasswordStdin -ForUser " + Q(Environment.UserDomainName + "\\" + Environment.UserName)
                    + " -SourceDir " + Q(SetupDir) + " -InstallDir " + Q(Dir)
                    + " -Server " + Q(s.Server.Trim()) + " -User " + Q(s.User.Trim()) + " -ProbeHost " + Q(s.ProbeHost.Trim())
                    + " -HomeNetworks " + Q(nets == "" ? "," : nets)   // a lone comma = no home networks (an empty value would keep the old list)
                    + (SkipTray || !s.Tray ? " -SkipTray" : "");
        ProcessStartInfo psi = new ProcessStartInfo(ps, args);
        psi.UseShellExecute = false; psi.CreateNoWindow = true;
        psi.RedirectStandardInput = true; psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
        psi.StandardOutputEncoding = Encoding.UTF8; psi.StandardErrorEncoding = Encoding.UTF8;
        psi.Environment.Remove("PSModulePath");   // PowerShell 7 module path breaks 5.1 (see install.ps1)
        onLine("> install.ps1 " + args.Substring(args.IndexOf("-NoPrompt")));
        using (Process p = new Process())
        {
            p.StartInfo = psi;
            p.OutputDataReceived += delegate(object o, DataReceivedEventArgs e) { if (e.Data != null) onLine(e.Data); };
            p.ErrorDataReceived += delegate(object o, DataReceivedEventArgs e) { if (e.Data != null) onLine("! " + e.Data); };
            p.Start();
            p.BeginOutputReadLine(); p.BeginErrorReadLine();
            p.StandardInput.WriteLine(password);   // empty line = keep the saved password
            p.StandardInput.Close();
            p.WaitForExit();
            return p.ExitCode;
        }
    }
}

// Wizard: 0 welcome -> 1 settings -> 2 installing -> 3 done / failed
public class Wizard : Form
{
    public int ExitCode = 1;
    int page;
    bool failed;
    Label head, sub, body;
    Panel optPanel;
    TextBox srvBox, usrBox, pw1Box, pw2Box, probeBox, netsBox, logBox;
    CheckBox trayBox;
    ProgressBar bar;
    Button back, next, cancel;
    StringBuilder errors = new StringBuilder();
    bool homeOk;
    static string T(string ru, string en) { return Setup.T(ru, en); }
    float scale = 1F;
    int S(int v) { return (int)Math.Round(v * scale); }
    Point P(int x, int y) { return new Point(S(x), S(y)); }
    Size Z(int w, int h) { return new Size(S(w), S(h)); }

    public Wizard()
    {
        SuspendLayout();
        AutoScaleMode = AutoScaleMode.None;   // scaled by hand: the coordinates below are logical px (96 dpi)
        using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) scale = g.DpiX / 96F;
        ClientSize = Z(520, 512);
        Text = T("Установка ", "Setup — ") + Setup.Title;
        Font = new Font("Segoe UI", 9F);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false; MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;

        Panel header = new Panel(); header.BackColor = Color.White; header.Location = P(0, 0); header.Size = Z(520, 66);
        head = new Label(); head.Font = new Font("Segoe UI", 11F, FontStyle.Bold); head.Location = P(18, 12); head.Size = Z(484, 24);
        sub = new Label(); sub.ForeColor = Color.FromArgb(90, 90, 90); sub.Location = P(18, 38); sub.Size = Z(484, 20);
        header.Controls.Add(head); header.Controls.Add(sub);
        Label line1 = new Label(); line1.BorderStyle = BorderStyle.Fixed3D; line1.Location = P(0, 66); line1.Size = Z(520, 2);

        body = new Label(); body.Location = P(24, 84); body.Size = Z(472, 368);

        // settings page
        KitSettings s = Setup.LoadSettings();
        optPanel = new Panel(); optPanel.Location = P(24, 80); optPanel.Size = Z(472, 380); optPanel.Visible = false;
        int y = 0;
        srvBox = Field(T("Адрес VPN-сервера (например vpn.example.com)", "VPN server address (e.g. vpn.example.com)"), s.Server, ref y, false);
        usrBox = Field(T("Логин VPN", "VPN login"), s.User, ref y, false);
        pw1Box = Field(T("Пароль VPN", "VPN password") + (Setup.CredExists ? T(" (пусто — оставить сохранённый)", " (empty — keep the saved one)") : ""), "", ref y, true);
        pw2Box = Field(T("Пароль ещё раз", "Password again"), "", ref y, true);
        probeBox = Field(T("Адрес в домашней сети для проверки (обычно роутер)", "Address in the home network to probe (usually the router)"), s.ProbeHost, ref y, false);
        netsBox = Field(T("Домашние сети, где VPN не нужен (через запятую, пусто — нет)", "Home networks where no VPN is needed (comma-separated, empty — none)"), s.Nets, ref y, false);
        List<string> now = Setup.ConnectedNetworks(s.Server);
        Label nowLbl = new Label(); nowLbl.ForeColor = Color.FromArgb(90, 90, 90); nowLbl.Location = P(0, y - 4); nowLbl.Size = Z(472, 18); nowLbl.AutoEllipsis = true;
        nowLbl.Text = now.Count > 0
            ? T("Сейчас компьютер подключён к: ", "Connected now to: ") + string.Join(", ", now.ToArray()) + T(" — если вы дома, впишите эту сеть.", " — if you are at home, enter that network.")
            : T("Сейчас сеть не определена.", "No network detected right now.");
        optPanel.Controls.Add(nowLbl); y += 18;
        trayBox = new CheckBox(); trayBox.Text = T("Индикатор VPN в трее (цветной кружок с меню «Disconnect / Connect VPN»)", "VPN indicator in the tray (coloured dot with a Disconnect / Connect VPN menu)");
        trayBox.Checked = !Setup.SkipTray; trayBox.Location = P(0, y + 4); trayBox.Size = Z(472, 24); optPanel.Controls.Add(trayBox); y += 28;
        Label note = new Label(); note.ForeColor = Color.FromArgb(90, 90, 90); note.Location = P(0, y + 2); note.Size = Z(472, 56);
        note.Text = T("Папка: " + Setup.Dir + ". Пароль хранится зашифрованным (DPAPI) только для этой учётной записи. "
                    + "Удаление: «Параметры» → «Приложения» → " + Setup.Title + ".",
                      "Folder: " + Setup.Dir + ". The password is stored encrypted (DPAPI) for this user account only. "
                    + "Uninstall: Settings → Apps → " + Setup.Title + ".");
        optPanel.Controls.Add(note);

        bar = new ProgressBar(); bar.Style = ProgressBarStyle.Marquee; bar.MarqueeAnimationSpeed = 30; bar.Location = P(24, 86); bar.Size = Z(472, 16); bar.Visible = false;
        logBox = new TextBox(); logBox.Multiline = true; logBox.ReadOnly = true; logBox.ScrollBars = ScrollBars.Vertical; logBox.WordWrap = false;
        logBox.Font = new Font("Consolas", 8.5F); logBox.BackColor = Color.White; logBox.Location = P(24, 110); logBox.Size = Z(472, 348); logBox.Visible = false; logBox.TabStop = false;

        Label line2 = new Label(); line2.BorderStyle = BorderStyle.Fixed3D; line2.Location = P(0, 466); line2.Size = Z(520, 2);
        back = new Button(); back.Text = T("< Назад", "< Back"); back.Location = P(226, 478); back.Size = Z(88, 26);
        next = new Button(); next.Location = P(320, 478); next.Size = Z(88, 26);
        cancel = new Button(); cancel.Text = T("Отмена", "Cancel"); cancel.Location = P(420, 478); cancel.Size = Z(88, 26);
        back.Click += delegate { ShowPage(0); };
        next.Click += delegate { if (page == 0) ShowPage(1); else if (page == 1) StartInstall(); else Close(); };
        cancel.Click += delegate { Close(); };
        AcceptButton = next; CancelButton = cancel;

        Controls.Add(bar); Controls.Add(logBox); Controls.Add(optPanel); Controls.Add(body);
        Controls.Add(header); Controls.Add(line1); Controls.Add(line2);
        Controls.Add(back); Controls.Add(next); Controls.Add(cancel);
        ResumeLayout(false);
        PerformLayout();

        FormClosing += delegate(object o, FormClosingEventArgs e) { if (page == 2) e.Cancel = true; };   // not while installing
        ShowPage(0);
    }

    TextBox Field(string label, string value, ref int y, bool password)
    {
        Label l = new Label(); l.Text = label; l.Location = P(0, y); l.Size = Z(472, 18); l.AutoEllipsis = true;
        TextBox b = new TextBox(); b.Text = value; b.Location = P(0, y + 18); b.Size = Z(472, 23); b.UseSystemPasswordChar = password;
        optPanel.Controls.Add(l); optPanel.Controls.Add(b);
        y += 46;
        return b;
    }

    public void ShowPage(int p)
    {
        page = p;
        optPanel.Visible = (p == 1);
        body.Visible = (p == 0 || (p == 3 && !failed));
        bar.Visible = (p == 2);
        logBox.Visible = (p == 2 || (p == 3 && failed));
        back.Visible = (p < 2); back.Enabled = (p == 1);
        next.Enabled = (p != 2);
        cancel.Enabled = (p < 2);
        switch (p)
        {
            case 0:
                head.Text = T("Установка ", "Welcome to ") + Setup.Title + T("", " Setup");
                sub.Text = T("VPN до домашней сети, который поднимается сам", "A home VPN that brings itself back up");
                body.Text = T("Этот установщик настроит на компьютере VPN до вашей домашней сети (OpenConnect / AnyConnect): "
                            + "туннель будет подниматься сам при входе в Windows и после каждого обрыва, а в трее появится "
                            + "цветной кружок — зелёный, когда дом доступен.\n\n"
                            + "Понадобятся адрес VPN-сервера, логин и пароль — их даёт тот, кто настраивал домашний роутер.\n\n"
                            + "Что будет установлено: OpenConnect-GUI (если его ещё нет), скрипты в " + Setup.Dir + ", "
                            + "три задачи Планировщика и индикатор в трее (с .NET Desktop Runtime, если его нет). "
                            + "Нужен интернет.\n\nНажмите «Далее», чтобы продолжить.",
                              "This setup configures a VPN to your home network (OpenConnect / AnyConnect) on this computer: "
                            + "the tunnel comes up by itself when you sign in to Windows and after every drop, and a coloured dot "
                            + "appears in the tray — green when home is reachable.\n\n"
                            + "You will need the VPN server address, login and password from whoever set up the home router.\n\n"
                            + "What gets installed: OpenConnect-GUI (if missing), scripts in " + Setup.Dir + ", "
                            + "three Task Scheduler tasks and the tray indicator (with .NET Desktop Runtime if missing). "
                            + "An internet connection is required.\n\nClick Next to continue.");
                next.Text = T("Далее >", "Next >");
                break;
            case 1:
                head.Text = T("Параметры VPN", "VPN settings");
                sub.Text = T("Заполните поля и нажмите «Установить»", "Fill in the fields and click Install");
                next.Text = T("Установить", "Install");
                (srvBox.Text == "" ? srvBox : (pw1Box.Text == "" && !Setup.CredExists ? pw1Box : srvBox)).Focus();
                break;
            case 2:
                head.Text = T("Установка", "Installing");
                sub.Text = T("Подождите: загрузка и настройка занимают 1–3 минуты", "Please wait: downloading and setting up takes 1–3 minutes");
                break;
            case 3:
                if (failed)
                {
                    head.Text = T("Установка не удалась", "Installation failed");
                    // the first stderr line is the message itself, the rest is PowerShell's trace
                    string first = errors.ToString().Split(new[] { "\r\n" }, StringSplitOptions.RemoveEmptyEntries)[0];
                    sub.Text = errors.Length > 0 ? first.Trim() : T("см. журнал ниже", "see the log below");
                    Line(T("Журнал установки: ", "Setup log: ") + Setup.LogFile);
                    next.Text = T("Закрыть", "Close");
                }
                else
                {
                    head.Text = T("Установка завершена", "Installation complete");
                    sub.Text = Setup.Title + T(" установлен", " is installed");
                    string home = homeOk
                        ? T("Домашняя сеть уже доступна. ", "Your home network is already reachable. ")
                        : T("Домашняя сеть пока не отвечает — туннель поднимется сам, как только появится связь с сервером. ",
                            "Home is not answering yet — the tunnel will come up by itself as soon as the server is reachable. ");
                    body.Text = home + T("Дальше ничего делать не нужно: VPN поднимается сам при входе в Windows и после обрывов.\n\n"
                              + "Кружок в трее: зелёный — дом доступен, красный — нет. Правый щелчок по нему — «Disconnect VPN» / «Connect VPN». "
                              + "В домашней сети из списка туннель не поднимается — там он не нужен.\n\n"
                              + "Журнал сторожа: " + Path.Combine(Setup.Dir, "watchdog.log") + "\n"
                              + "Удаление: «Параметры» → «Приложения» → " + Setup.Title + ".",
                                "Nothing else to do: the VPN comes up by itself when you sign in to Windows and after drops.\n\n"
                              + "The tray dot: green — home is reachable, red — it is not. Right-click it for Disconnect VPN / Connect VPN. "
                              + "On a listed home network the tunnel is not started — it is not needed there.\n\n"
                              + "Watchdog log: " + Path.Combine(Setup.Dir, "watchdog.log") + "\n"
                              + "Uninstall: Settings → Apps → " + Setup.Title + ".");
                    next.Text = T("Готово", "Finish");
                }
                next.Focus();
                break;
        }
    }

    bool CheckFields()
    {
        string bad = null;
        if (srvBox.Text.Trim() == "") bad = T("Укажите адрес VPN-сервера.", "Enter the VPN server address.");
        else if (usrBox.Text.Trim() == "") bad = T("Укажите логин VPN.", "Enter the VPN login.");
        else if (pw1Box.Text == "" && !Setup.CredExists) bad = T("Введите пароль VPN.", "Enter the VPN password.");
        else if (pw1Box.Text != pw2Box.Text) bad = T("Пароли не совпадают.", "The passwords do not match.");
        else if (probeBox.Text.Trim() == "") bad = T("Укажите адрес для проверки (обычно 192.168.1.1).", "Enter the address to probe (usually 192.168.1.1).");
        else foreach (TextBox b in new[] { srvBox, usrBox, pw1Box, probeBox, netsBox })
            if (b.Text.IndexOf('"') >= 0) { bad = T("Кавычки в полях недопустимы.", "Quotation marks are not allowed."); break; }
        if (bad != null) { MessageBox.Show(this, bad, Setup.Title, MessageBoxButtons.OK, MessageBoxIcon.Warning); return false; }
        return true;
    }

    void StartInstall()
    {
        if (!CheckFields()) return;
        KitSettings s = new KitSettings();
        s.Server = srvBox.Text; s.User = usrBox.Text; s.ProbeHost = probeBox.Text; s.Nets = netsBox.Text; s.Tray = trayBox.Checked;
        string pw = pw1Box.Text;
        pw1Box.Text = ""; pw2Box.Text = "";
        logBox.Clear(); errors.Length = 0; homeOk = false;
        ShowPage(2);
        Task.Factory.StartNew<int>(delegate
        {
            try { return Setup.RunInstall(s, pw, Line); }
            catch (Exception ex) { Line("! " + ex.Message); return 1; }
        }).ContinueWith(delegate(Task<int> t) { Done(t.Result); }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    void Line(string text)
    {
        Setup.Log(text);
        if (text.StartsWith("! ")) errors.AppendLine(text.Substring(2));
        if (text.Contains("ok: домашняя сеть доступна")) homeOk = true;
        if (IsHandleCreated) BeginInvoke((Action)delegate { logBox.AppendText(text + "\r\n"); });
    }

    void Done(int code)
    {
        ExitCode = code;
        failed = (code != 0);
        if (failed && errors.Length == 0) errors.AppendLine(T("install.ps1 завершился с кодом ", "install.ps1 exited with code ") + code);
        ShowPage(3);
        Activate();
    }
}
