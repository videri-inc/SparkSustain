// SparkSustain for Windows — keeps the Videri Spark displays near your desk
// in sync with your laptop: awake at your desk = on, everything else = dark.
//
// Compiled on the user's machine by Install-SparkSustain.bat using the C#
// compiler that ships with Windows (.NET Framework 4.x, C# 5 syntax only).

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Management;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;
using System.IO.Compression;
using System.Security.Cryptography;

namespace SparkSustain
{
    public static class AppInfo
    {
        public const string Version = "1.6";
    }

    public static class AppInfo
    {
        public const string Version = "1.11";
        // Manifest on the repo's main branch; zips are release assets.
        public const string DefaultUpdateUrl =
            "https://raw.githubusercontent.com/videri-inc/SparkSustain/main/updates/manifest.json";
    }

    // ------------------------------------------------------------------ config

    public class CanvasTarget
    {
        public string name = "";
        public string device_id = "";
        public string device_jid = "";
        public string player_id = "";
        public string tenant = "";
    }

    public class Config
    {
        public string api_base_url = "https://api.go.videri.com";
        public string username = "";
        public string password = "";
        public string api_key = "";
        public string tenant = "";
        // Workspaces (tenants) this install may see and control; empty = all.
        public List<string> workspaces = new List<string>();
        // Per-tenant sub-workspace scoping: tenant -> checked group UUIDs.
        // A checked group includes everything nested beneath it. Empty list
        // (or no entry) = the whole tenant.
        public Dictionary<string, List<string>> workspace_groups =
            new Dictionary<string, List<string>>();
        public int wake_brightness_percent = 70;
        public int sleep_brightness_percent = 0;
        // How long a hotkey toggle holds its state before automation resumes.
        public int default_override_minutes = 60;
        public List<string> office_network_prefixes = new List<string>();
        // Desk condition: AC power connected AND this PnP device present
        // (e.g. the USB-C dock or monitor at the desk). Empty = not required.
        public string desk_device_id = "";
        public string desk_device_name = "";
        public bool schedules_overridden_asked = false;
        // Override for the update manifest URL (default: the GitHub repo).
        public string update_url = "";
        public List<CanvasTarget> canvases = new List<CanvasTarget>();

        public bool HasCredentials()
        {
            return username.Length > 0 && password.Length > 0 && api_key.Length > 0;
        }
        public bool IsFilledIn()
        {
            return HasCredentials() && canvases.Any(c => c.device_jid.Length > 0);
        }
        public List<CanvasTarget> ReadyTargets()
        {
            return canvases.Where(c => c.device_jid.Length > 0).ToList();
        }
    }

    public static class Paths
    {
        public static string Dir
        {
            get
            {
                string d = Path.Combine(Environment.GetFolderPath(
                    Environment.SpecialFolder.ApplicationData), "SparkSustain");
                Directory.CreateDirectory(d);
                return d;
            }
        }
        public static string ConfigFile { get { return Path.Combine(Dir, "config.json"); } }
        public static string CanvasesFile { get { return Path.Combine(Dir, "canvases.json"); } }
        public static string LogFile { get { return Path.Combine(Dir, "SparkSustain.log"); } }
    }

    public static class Store
    {
        static readonly JavaScriptSerializer json = new JavaScriptSerializer();

        public static Config Load()
        {
            try
            {
                if (!File.Exists(Paths.ConfigFile)) return null;
                return json.Deserialize<Config>(File.ReadAllText(Paths.ConfigFile));
            }
            catch (Exception e) { Log.Write("Config load error: " + e.Message); return null; }
        }
        public static void Save(Config c)
        {
            try { File.WriteAllText(Paths.ConfigFile, json.Serialize(c)); }
            catch (Exception e) { Log.Write("Config save error: " + e.Message); }
        }
    }

    public static class Log
    {
        static readonly object gate = new object();
        public static void Write(string message)
        {
            try
            {
                lock (gate)
                {
                    File.AppendAllText(Paths.LogFile, string.Format(
                        "[{0:yyyy-MM-ddTHH:mm:ssZ}] {1}\r\n", DateTime.UtcNow, message));
                }
            }
            catch { }
        }
    }

    // ---------------------------------------------------------- environment

    public static class Env
    {
        public static List<string> LocalIPv4()
        {
            var result = new List<string>();
            try
            {
                foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (nic.OperationalStatus != OperationalStatus.Up) continue;
                    if (nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                    foreach (var addr in nic.GetIPProperties().UnicastAddresses)
                    {
                        if (addr.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                        string s = addr.Address.ToString();
                        if (!s.StartsWith("169.254.")) result.Add(s);
                    }
                }
            }
            catch (Exception e) { Log.Write("IP enumeration error: " + e.Message); }
            return result;
        }

        public static string SubnetPrefix(string ip)
        {
            var parts = ip.Split('.');
            if (parts.Length != 4) return null;
            return parts[0] + "." + parts[1] + "." + parts[2] + ".";
        }

        public static bool OnOfficeNetwork(Config c)
        {
            var prefixes = (c.office_network_prefixes ?? new List<string>())
                .Where(p => p.Length > 0).ToList();
            if (prefixes.Count == 0) return true;
            var locals = LocalIPv4();
            return locals.Any(ip => prefixes.Any(p => ip.StartsWith(p)));
        }

        public static bool OnACPower()
        {
            return SystemInformation.PowerStatus.PowerLineStatus == PowerLineStatus.Online;
        }

        public static bool DevicePresent(string deviceIdFragment)
        {
            if (string.IsNullOrEmpty(deviceIdFragment)) return false;
            try
            {
                string escaped = deviceIdFragment.Replace("\\", "\\\\").Replace("'", "''");
                // Present=TRUE alone is not enough: a powered-off monitor can
                // stay enumerated. Require a fully healthy device (error code
                // 0 and Status OK) so power-off states register as absent
                // wherever the driver reports them.
                using (var searcher = new ManagementObjectSearcher(
                    "SELECT DeviceID, ConfigManagerErrorCode, Status FROM Win32_PnPEntity " +
                    "WHERE Present=TRUE AND DeviceID LIKE '%" + escaped + "%'"))
                {
                    foreach (ManagementObject o in searcher.Get())
                    {
                        int code = 0;
                        try { if (o["ConfigManagerErrorCode"] != null) code = Convert.ToInt32(o["ConfigManagerErrorCode"]); }
                        catch { }
                        string status = Convert.ToString(o["Status"]) ?? "OK";
                        if (code == 0 && (status == "OK" || status.Length == 0)) return true;
                    }
                }
            }
            catch (Exception e) { Log.Write("Device query error: " + e.Message); }
            return false;
        }

        public static bool OnDeskPower(Config c)
        {
            if (string.IsNullOrEmpty(c.desk_device_id)) return true;   // not required
            return OnACPower() && DevicePresent(c.desk_device_id);
        }

        // Candidate anchor devices for the desk: monitors and USB devices.
        public static List<KeyValuePair<string, string>> PresentDevices()
        {
            var result = new List<KeyValuePair<string, string>>();
            try
            {
                using (var searcher = new ManagementObjectSearcher(
                    "SELECT DeviceID, Name, PNPClass FROM Win32_PnPEntity WHERE Present=TRUE"))
                {
                    foreach (ManagementObject o in searcher.Get())
                    {
                        string cls = Convert.ToString(o["PNPClass"]) ?? "";
                        if (cls != "Monitor" && cls != "USB" && cls != "USBDevice"
                            && cls != "HIDClass" && cls != "Net") continue;
                        string name = Convert.ToString(o["Name"]) ?? "";
                        string id = Convert.ToString(o["DeviceID"]) ?? "";
                        if (name.Length == 0 || id.Length == 0) continue;
                        result.Add(new KeyValuePair<string, string>(
                            name + "  [" + cls + "]", id));
                    }
                }
            }
            catch (Exception e) { Log.Write("Device enumeration error: " + e.Message); }
            // USB devices first: they disappear when their host loses power.
            // Monitor entries last: HDMI/DP EDID registrations often persist
            // while the screen is merely powered off.
            Func<string, int> rank = delegate(string label)
            {
                if (label.Contains("[USB]") || label.Contains("[USBDevice]")) return 0;
                if (label.Contains("[Net]")) return 1;
                if (label.Contains("[HIDClass]")) return 2;
                return 3;   // Monitor
            };
            return result.OrderBy(kv => rank(kv.Key)).ThenBy(kv => kv.Key).ToList();
        }
    }

    // -------------------------------------------------------------- Videri API

    public class VideriClient
    {
        readonly JavaScriptSerializer json = new JavaScriptSerializer();
        string cachedToken;
        DateTime tokenExpiry = DateTime.MinValue;
        List<string> tokenTenants = new List<string>();
        readonly object gate = new object();

        static VideriClient()
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
        }

        public void InvalidateToken()
        {
            lock (gate) { cachedToken = null; tokenExpiry = DateTime.MinValue; }
        }

        string Http(string method, string url, string bearer, string tenant,
                    string body, out int status)
        {
            var req = (HttpWebRequest)WebRequest.Create(url);
            req.Method = method;
            req.Timeout = 20000;
            if (bearer != null) req.Headers["Authorization"] = "Bearer " + bearer;
            if (!string.IsNullOrEmpty(tenant)) req.Headers["x-tenant"] = tenant;
            if (body != null)
            {
                req.ContentType = "application/json";
                var bytes = Encoding.UTF8.GetBytes(body);
                req.ContentLength = bytes.Length;
                using (var s = req.GetRequestStream()) s.Write(bytes, 0, bytes.Length);
            }
            try
            {
                using (var resp = (HttpWebResponse)req.GetResponse())
                using (var reader = new StreamReader(resp.GetResponseStream()))
                {
                    status = (int)resp.StatusCode;
                    return reader.ReadToEnd();
                }
            }
            catch (WebException e)
            {
                var resp = e.Response as HttpWebResponse;
                if (resp == null) throw;
                using (var reader = new StreamReader(resp.GetResponseStream()))
                {
                    status = (int)resp.StatusCode;
                    return reader.ReadToEnd();
                }
            }
        }

        string Token(Config c)
        {
            lock (gate)
            {
                if (cachedToken != null && tokenExpiry > DateTime.UtcNow.AddMinutes(5))
                    return cachedToken;
                int status;
                var body = json.Serialize(new Dictionary<string, string> {
                    { "username", c.username }, { "password", c.password },
                    { "api_key", c.api_key } });
                var text = Http("POST", c.api_base_url + "/rpm-service/v2/auth/token",
                                null, null, body, out status);
                if (status != 200)
                    throw new Exception("Sign-in failed (HTTP " + status + "). Check username, password, and API key.");
                var dict = json.Deserialize<Dictionary<string, object>>(text);
                cachedToken = Convert.ToString(dict["id_token"]);
                double expires = dict.ContainsKey("expires_in")
                    ? Convert.ToDouble(dict["expires_in"]) : 3600;
                tokenExpiry = DateTime.UtcNow.AddSeconds(expires);
                ParseTenants(cachedToken);
                Log.Write("Obtained API token; tenants: " + string.Join(",", tokenTenants));
                return cachedToken;
            }
        }

        void ParseTenants(string jwt)
        {
            try
            {
                var parts = jwt.Split('.');
                if (parts.Length < 2) return;
                string payload = parts[1].Replace('-', '+').Replace('_', '/');
                while (payload.Length % 4 != 0) payload += "=";
                var text = Encoding.UTF8.GetString(Convert.FromBase64String(payload));
                var claims = json.Deserialize<Dictionary<string, object>>(text);
                if (!claims.ContainsKey("tenants")) return;
                var names = json.Deserialize<List<string>>(Convert.ToString(claims["tenants"]));
                if (names != null && names.Count > 0) tokenTenants = names;
            }
            catch (Exception e) { Log.Write("Tenant claim parse error: " + e.Message); }
        }

        public List<string> AllTokenTenants(Config c)
        {
            Token(c);
            lock (gate)
            {
                return tokenTenants.Count > 0 ? new List<string>(tokenTenants)
                                              : new List<string> { "" };
            }
        }

        public List<string> AvailableTenants(Config c)
        {
            if (c.workspaces != null && c.workspaces.Count > 0)
                return new List<string>(c.workspaces);
            if (!string.IsNullOrEmpty(c.tenant)) return new List<string> { c.tenant };
            return AllTokenTenants(c);
        }

        public void ValidateCredentials(Config c)
        {
            InvalidateToken();
            Token(c);
        }

        public class GroupNode
        {
            public string Uuid = "";
            public string Name = "";
            public List<GroupNode> Children = new List<GroupNode>();
        }

        // The current user's workspace (group) tree for one tenant.
        public List<GroupNode> FetchGroupTree(Config c, string tenant)
        {
            int status;
            var text = Http("GET", c.api_base_url + "/rpm/v1/users/me/groups_access",
                            Token(c), tenant, null, out status);
            if (status == 401 || status == 403) InvalidateToken();
            if (status < 200 || status >= 300)
                throw new Exception("groups_access HTTP " + status);
            var dict = json.Deserialize<Dictionary<string, object>>(text);
            if (!dict.ContainsKey("groupAccess")) return new List<GroupNode>();
            return ParseGroups(dict["groupAccess"] as System.Collections.ArrayList);
        }

        List<GroupNode> ParseGroups(System.Collections.ArrayList nodes)
        {
            var result = new List<GroupNode>();
            if (nodes == null) return result;
            foreach (var item in nodes)
            {
                var d = item as Dictionary<string, object>;
                if (d == null || !d.ContainsKey("uuid")) continue;
                var node = new GroupNode();
                node.Uuid = Convert.ToString(d["uuid"]);
                node.Name = d.ContainsKey("displayName") && d["displayName"] != null
                    ? Convert.ToString(d["displayName"]) : node.Uuid;
                if (d.ContainsKey("descendants"))
                    node.Children = ParseGroups(d["descendants"] as System.Collections.ArrayList);
                result.Add(node);
            }
            return result;
        }

        // A checked node grants itself plus its entire subtree.
        public static List<string> ExpandGroups(HashSet<string> checkedIds, List<GroupNode> tree)
        {
            var result = new HashSet<string>();
            Action<List<GroupNode>, bool> walk = null;
            walk = delegate(List<GroupNode> nodes, bool inherited)
            {
                foreach (var node in nodes)
                {
                    bool selected = inherited || checkedIds.Contains(node.Uuid);
                    if (selected) result.Add(node.Uuid);
                    walk(node.Children, selected);
                }
            };
            walk(tree, false);
            return result.ToList();
        }

        List<Dictionary<string, object>> CanvasPage(Config c, string tenant, bool assigned,
                                                    List<string> groupUuids)
        {
            int status;
            string url = c.api_base_url + "/canvas-service/canvases?assigned_to_group=" +
                (assigned ? "true" : "false") + "&size=1000";
            if (groupUuids != null && groupUuids.Count > 0)
                url += "&group_uuid=" + string.Join(",", groupUuids);
            var text = Http("GET", url, Token(c), tenant, null, out status);
            if (status == 401 || status == 403) InvalidateToken();
            if (status < 200 || status >= 300)
                throw new Exception("HTTP " + status + ": " + Truncate(text, 200));
            var dict = json.Deserialize<Dictionary<string, object>>(text);
            foreach (var key in new[] { "content", "data", "canvases" })
            {
                if (dict.ContainsKey(key) && dict[key] is System.Collections.ArrayList)
                {
                    var result = new List<Dictionary<string, object>>();
                    foreach (var item in (System.Collections.ArrayList)dict[key])
                    {
                        var d = item as Dictionary<string, object>;
                        if (d != null) result.Add(d);
                    }
                    return result;
                }
            }
            return new List<Dictionary<string, object>>();
        }

        public List<CanvasTarget> FetchCanvases(Config c, out List<string> labels)
        {
            var targets = new List<CanvasTarget>();
            labels = new List<string>();
            var errors = new List<string>();
            foreach (var tenant in AvailableTenants(c))
            {
                try
                {
                    List<Dictionary<string, object>> items;
                    List<string> scoped;
                    if (c.workspace_groups != null
                        && c.workspace_groups.TryGetValue(tenant, out scoped)
                        && scoped != null && scoped.Count > 0)
                    {
                        var uuids = scoped;
                        try
                        {
                            var tree = FetchGroupTree(c, tenant);
                            var expanded = ExpandGroups(new HashSet<string>(scoped), tree);
                            if (expanded.Count > 0) uuids = expanded;
                        }
                        catch { }
                        items = CanvasPage(c, tenant, true, uuids);
                    }
                    else
                    {
                        items = CanvasPage(c, tenant, false, null);
                        if (items.Count == 0) items = CanvasPage(c, tenant, true, null);
                        else
                        {
                            var seen = new HashSet<string>(items.Select(i => Str(i, "device_id")));
                            try
                            {
                                foreach (var extra in CanvasPage(c, tenant, true, null))
                                    if (!seen.Contains(Str(extra, "device_id"))) items.Add(extra);
                            }
                            catch { }
                        }
                    }
                    foreach (var item in items)
                    {
                        var target = new CanvasTarget();
                        target.name = Str(item, "name");
                        target.device_id = Str(item, "device_id");
                        target.device_jid = Str(item, "xmpp_jid");
                        target.player_id = Str(item, "id");
                        target.tenant = tenant;
                        targets.Add(target);
                        string presence = Str(item, "presence_status");
                        string product = Str(item, "product_name");
                        labels.Add(target.name
                            + (product.Length > 0 ? " — " + product : "")
                            + (tenant.Length > 0 ? ", " + tenant : "")
                            + (presence.Length > 0 ? "  [" + presence + "]" : ""));
                    }
                }
                catch (Exception e)
                {
                    errors.Add(tenant + ": " + e.Message);
                    Log.Write("Canvas fetch failed for tenant " + tenant + ": " + e.Message);
                }
            }
            if (targets.Count == 0 && errors.Count > 0)
                throw new Exception(string.Join(" | ", errors));
            return targets;
        }

        static string Str(Dictionary<string, object> d, string key)
        {
            return d.ContainsKey(key) && d[key] != null ? Convert.ToString(d[key]) : "";
        }
        static string Truncate(string s, int n)
        {
            return s == null ? "" : (s.Length <= n ? s : s.Substring(0, n));
        }

        // one sync_command; returns null on SUCCESS, error text otherwise
        string SyncCommand(Config c, CanvasTarget t, string tenant,
                           string name, Dictionary<string, object> parameters)
        {
            try
            {
                var payload = new Dictionary<string, object> {
                    { "message_id", Guid.NewGuid().ToString() },
                    { "command_name", name },
                    { "command_params", parameters },
                    { "device_id", t.device_id },
                    { "device_jid", t.device_jid },
                    { "player_id", string.IsNullOrEmpty(t.player_id) ? t.device_id : t.player_id }
                };
                int status;
                var text = Http("POST",
                    c.api_base_url + "/messaging-websocket/messaging/sync_command",
                    Token(c), tenant, json.Serialize(payload), out status);
                if (status == 401 || status == 403) InvalidateToken();
                if (status < 200 || status >= 300)
                    return "HTTP " + status + ": " + Truncate(text, 150);
                var dict = json.Deserialize<Dictionary<string, object>>(text);
                string code = Str(dict, "response_code");
                return code == "SUCCESS" ? null : name + ": " + code;
            }
            catch (Exception e) { return name + ": " + e.Message; }
        }

        string ApplyToCanvas(Config c, CanvasTarget t, string tenant, int value)
        {
            var power = new Dictionary<string, object> {
                { "system_properties", new Dictionary<string, object> {
                    { "display_on", value > 0 },
                    { "brightness_schedule_enabled", false } } } };
            string error = SyncCommand(c, t, tenant, "ops_set_settings", power);
            if (error != null) return error;
            if (value <= 0) return null;
            var demo = new Dictionary<string, object> {
                { "arg", "set_brightness:=" + value },
                { "command", "demo_command" },
                { "api_version", 1 } };
            return SyncCommand(c, t, tenant, "demo_command", demo);
        }

        public string SetBrightness(Config c, int percent)
        {
            int value = Math.Max(0, Math.Min(255, (int)Math.Round(percent * 255.0 / 100.0)));
            var targets = c.ReadyTargets();
            if (targets.Count == 0) throw new Exception("no canvases configured");
            string fallback = AvailableTenants(c).FirstOrDefault() ?? "";
            int succeeded = 0;
            var failures = new List<string>();
            var done = new CountdownEvent(targets.Count);
            var gate2 = new object();
            foreach (var target in targets)
            {
                var t = target;
                string tenant = string.IsNullOrEmpty(t.tenant) ? fallback : t.tenant;
                ThreadPool.QueueUserWorkItem(delegate
                {
                    string error = ApplyToCanvas(c, t, tenant, value);
                    lock (gate2)
                    {
                        if (error == null)
                        {
                            succeeded++;
                            Log.Write("Brightness " + value + "/255 OK for " + t.name);
                        }
                        else
                        {
                            failures.Add(t.name + ": " + error);
                            Log.Write("Brightness " + value + "/255 FAILED for " + t.name + ": " + error);
                        }
                    }
                    done.Signal();
                });
            }
            done.Wait(25000);
            if (succeeded == 0) throw new Exception(string.Join(" | ", failures));
            string suffix = failures.Count == 0 ? ""
                : " — " + failures.Count + " failed";
            return "Applied " + percent + "% to " + succeeded + "/" + targets.Count
                + " canvases" + suffix;
        }

        public string DeleteBrightnessSchedules(Config c)
        {
            var targets = c.ReadyTargets();
            if (targets.Count == 0) throw new Exception("no canvases configured");
            string fallback = AvailableTenants(c).FirstOrDefault() ?? "";
            int deleted = 0;
            var errors = new List<string>();
            var groups = targets.GroupBy(t => string.IsNullOrEmpty(t.tenant) ? fallback : t.tenant);
            foreach (var group in groups)
            {
                var ids = new List<int>();
                foreach (var t in group)
                {
                    int id;
                    if (int.TryParse(t.player_id, out id)) ids.Add(id);
                }
                if (ids.Count == 0) continue;
                string body = json.Serialize(new Dictionary<string, object> { { "canvasIds", ids } });
                string groupError = null;
                foreach (var path in new[] { "/publisher/api/v1/canvas_settings_events",
                                             "/api/v1/canvas_settings_events" })
                {
                    int status;
                    var text = Http("DELETE", c.api_base_url + path,
                                    Token(c), group.Key, body, out status);
                    if (status >= 200 && status < 300)
                    {
                        try
                        {
                            var dict = json.Deserialize<Dictionary<string, object>>(text);
                            if (dict != null && dict.ContainsKey("numberOfSuccessfulEventsDeletion"))
                                deleted += Convert.ToInt32(dict["numberOfSuccessfulEventsDeletion"]);
                        }
                        catch { }
                        Log.Write("Deleted brightness schedules for " + ids.Count
                            + " canvases (tenant " + group.Key + ")");
                        groupError = null;
                        break;
                    }
                    if (status == 401 || status == 403) InvalidateToken();
                    groupError = "HTTP " + status + " at " + path;
                }
                if (groupError != null) errors.Add(group.Key + ": " + groupError);
            }
            if (errors.Count > 0 && deleted == 0)
                throw new Exception(string.Join(" | ", errors));
            return "Deleted " + deleted + " brightness schedule event(s)"
                + (errors.Count > 0 ? " (some failed)" : "");
        }
    }

    // ------------------------------------------------------------ setup forms

    public class CredentialsForm : Form
    {
        public TextBox UserBox = new TextBox();
        public TextBox PassBox = new TextBox();
        public TextBox KeyBox = new TextBox();

        public CredentialsForm(Config c)
        {
            Text = "SparkSustain — Pair your API key";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false; MinimizeBox = false;
            ClientSize = new Size(420, 210);
            StartPosition = FormStartPosition.CenterScreen;

            var info = new Label();
            info.Text = "Credentials are stored only on this PC, readable only by you.";
            info.SetBounds(15, 10, 390, 20);
            Controls.Add(info);

            AddRow("Username", UserBox, 40); UserBox.Text = c.username;
            AddRow("Password", PassBox, 75); PassBox.UseSystemPasswordChar = true;
            AddRow("API key", KeyBox, 110); KeyBox.Text = c.api_key;

            var ok = new Button(); ok.Text = "Verify && Continue";
            ok.DialogResult = DialogResult.OK; ok.SetBounds(200, 160, 130, 28);
            var cancel = new Button(); cancel.Text = "Cancel";
            cancel.DialogResult = DialogResult.Cancel; cancel.SetBounds(340, 160, 65, 28);
            Controls.Add(ok); Controls.Add(cancel);
            AcceptButton = ok; CancelButton = cancel;
        }

        void AddRow(string label, TextBox box, int y)
        {
            var l = new Label(); l.Text = label; l.SetBounds(15, y + 3, 80, 20);
            box.SetBounds(100, y, 305, 24);
            Controls.Add(l); Controls.Add(box);
        }
    }

    public class PickerForm : Form
    {
        readonly List<CanvasTarget> all;
        readonly List<string> labels;
        readonly HashSet<string> chosen = new HashSet<string>();
        readonly TextBox filter = new TextBox();
        readonly CheckedListBox list = new CheckedListBox();
        readonly List<int> visible = new List<int>();

        public PickerForm(List<CanvasTarget> targets, List<string> targetLabels,
                          HashSet<string> preselected)
        {
            all = targets; labels = targetLabels;
            foreach (var jid in preselected) chosen.Add(jid);

            Text = "SparkSustain — Pick the Sparks near your desk";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false; MinimizeBox = false;
            ClientSize = new Size(520, 420);
            StartPosition = FormStartPosition.CenterScreen;

            filter.SetBounds(15, 12, 490, 24);
            var hint = new Label(); hint.Text = "Filter:"; hint.SetBounds(15, 12, 0, 0);
            filter.TextChanged += delegate { Rebuild(); };
            Controls.Add(filter);

            list.SetBounds(15, 45, 490, 320);
            list.CheckOnClick = true;
            list.ItemCheck += delegate(object s, ItemCheckEventArgs e)
            {
                string jid = all[visible[e.Index]].device_jid;
                if (e.NewValue == CheckState.Checked) chosen.Add(jid);
                else chosen.Remove(jid);
            };
            Controls.Add(list);

            var ok = new Button(); ok.Text = "Continue";
            ok.DialogResult = DialogResult.OK; ok.SetBounds(330, 378, 90, 28);
            var cancel = new Button(); cancel.Text = "Cancel";
            cancel.DialogResult = DialogResult.Cancel; cancel.SetBounds(430, 378, 75, 28);
            Controls.Add(ok); Controls.Add(cancel);
            AcceptButton = ok; CancelButton = cancel;
            Rebuild();
        }

        void Rebuild()
        {
            string q = filter.Text.ToLowerInvariant();
            list.Items.Clear();
            visible.Clear();
            for (int i = 0; i < all.Count; i++)
            {
                if (q.Length > 0 && !labels[i].ToLowerInvariant().Contains(q)) continue;
                visible.Add(i);
                list.Items.Add(labels[i], chosen.Contains(all[i].device_jid));
            }
        }

        public List<CanvasTarget> Selected()
        {
            return all.Where(t => chosen.Contains(t.device_jid)).ToList();
        }
    }

    public class WorkspaceTreeForm : Form
    {
        readonly TreeView tree = new TreeView();

        // Node.Tag: string tenant for roots; string[]{tenant, uuid} for groups
        public WorkspaceTreeForm(Dictionary<string, List<VideriClient.GroupNode>> forest,
                                 HashSet<string> selectedTenants,
                                 HashSet<string> selectedGroups)
        {
            Text = "SparkSustain — Choose your workspaces";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false; MinimizeBox = false;
            ClientSize = new Size(480, 470);
            StartPosition = FormStartPosition.CenterScreen;

            var info = new Label();
            info.Text = "SparkSustain will only show — and only ever control — displays in what\r\n"
                + "you check. Check a workspace to include everything inside it, or check\r\n"
                + "just the sub-workspaces you need. Most people need one sub-workspace.";
            info.SetBounds(15, 8, 450, 50);
            Controls.Add(info);

            tree.SetBounds(15, 62, 450, 355);
            tree.CheckBoxes = true;
            foreach (var pair in forest)
            {
                var root = new TreeNode(pair.Key);
                root.Tag = pair.Key;
                root.NodeFont = new Font(Font, FontStyle.Bold);
                root.Checked = selectedTenants.Contains(pair.Key);
                AddChildren(root, pair.Key, pair.Value, selectedGroups);
                tree.Nodes.Add(root);
                if (HasCheckedDescendant(root)) root.Expand();
            }
            Controls.Add(tree);

            var ok = new Button(); ok.Text = "Continue";
            ok.DialogResult = DialogResult.OK; ok.SetBounds(290, 428, 90, 28);
            var cancel = new Button(); cancel.Text = "Cancel";
            cancel.DialogResult = DialogResult.Cancel; cancel.SetBounds(390, 428, 75, 28);
            Controls.Add(ok); Controls.Add(cancel);
            AcceptButton = ok; CancelButton = cancel;
        }

        void AddChildren(TreeNode parent, string tenant,
                         List<VideriClient.GroupNode> nodes, HashSet<string> selectedGroups)
        {
            foreach (var g in nodes)
            {
                var child = new TreeNode(g.Name);
                child.Tag = new string[] { tenant, g.Uuid };
                child.Checked = selectedGroups.Contains(g.Uuid);
                AddChildren(child, tenant, g.Children, selectedGroups);
                parent.Nodes.Add(child);
            }
        }

        static bool HasCheckedDescendant(TreeNode node)
        {
            foreach (TreeNode child in node.Nodes)
            {
                if (child.Checked || HasCheckedDescendant(child)) return true;
            }
            return false;
        }

        public bool HasAnySelection()
        {
            return AnyChecked(tree.Nodes);
        }

        static bool AnyChecked(TreeNodeCollection nodes)
        {
            foreach (TreeNode node in nodes)
                if (node.Checked || AnyChecked(node.Nodes)) return true;
            return false;
        }

        // tenant -> checked group uuids; a root check maps to [] (whole tenant)
        public Dictionary<string, List<string>> Selection()
        {
            var result = new Dictionary<string, List<string>>();
            foreach (TreeNode root in tree.Nodes)
            {
                string tenant = Convert.ToString(root.Tag);
                var groups = new List<string>();
                CollectChecked(root.Nodes, groups);
                if (root.Checked) result[tenant] = new List<string>();
                else if (groups.Count > 0) result[tenant] = groups;
            }
            return result;
        }

        static void CollectChecked(TreeNodeCollection nodes, List<string> into)
        {
            foreach (TreeNode node in nodes)
            {
                if (node.Checked)
                {
                    var tag = node.Tag as string[];
                    if (tag != null && tag.Length == 2) into.Add(tag[1]);
                }
                CollectChecked(node.Nodes, into);
            }
        }
    }

    public class DevicePickerForm : Form
    {
        readonly List<KeyValuePair<string, string>> devices;
        readonly ListBox list = new ListBox();
        readonly TextBox filter = new TextBox();
        readonly List<int> visible = new List<int>();

        public DevicePickerForm(List<KeyValuePair<string, string>> present)
        {
            devices = present;
            Text = "SparkSustain — Pick your desk dock or monitor";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false; MinimizeBox = false;
            ClientSize = new Size(560, 420);
            StartPosition = FormStartPosition.CenterScreen;

            var info = new Label();
            info.Text = "Pick the device that means \"I'm at my desk\" — best: a USB device from your\r\n"
                + "dock or USB-C monitor. Avoid [Monitor] entries: HDMI/DP screens often stay\r\n"
                + "listed even when powered off, so SparkSustain wouldn't notice you leaving.";
            info.SetBounds(15, 8, 530, 48);
            Controls.Add(info);

            filter.SetBounds(15, 60, 530, 24);
            filter.TextChanged += delegate { Rebuild(); };
            Controls.Add(filter);

            list.SetBounds(15, 92, 530, 272);
            Controls.Add(list);

            var ok = new Button(); ok.Text = "Use This Device";
            ok.DialogResult = DialogResult.OK; ok.SetBounds(340, 378, 120, 28);
            var cancel = new Button(); cancel.Text = "Skip";
            cancel.DialogResult = DialogResult.Cancel; cancel.SetBounds(470, 378, 75, 28);
            Controls.Add(ok); Controls.Add(cancel);
            AcceptButton = ok; CancelButton = cancel;
            Rebuild();
        }

        void Rebuild()
        {
            string q = filter.Text.ToLowerInvariant();
            list.Items.Clear(); visible.Clear();
            for (int i = 0; i < devices.Count; i++)
            {
                if (q.Length > 0 && !devices[i].Key.ToLowerInvariant().Contains(q)) continue;
                visible.Add(i);
                list.Items.Add(devices[i].Key);
            }
        }

        public KeyValuePair<string, string>? Chosen()
        {
            if (list.SelectedIndex < 0) return null;
            return devices[visible[list.SelectedIndex]];
        }
    }

    // ------------------------------------------------------------- auto-update

    public static class Updater
    {
        static readonly JavaScriptSerializer json = new JavaScriptSerializer();

        static Updater()
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
        }

        public static Dictionary<string, object> FetchManifest(string url)
        {
            try
            {
                using (var web = new WebClient())
                {
                    web.Headers["User-Agent"] = "SparkSustain-Updater";
                    return json.Deserialize<Dictionary<string, object>>(web.DownloadString(url));
                }
            }
            catch (Exception e) { Log.Write("Manifest fetch failed: " + e.Message); return null; }
        }

        public static bool Download(string url, string destination)
        {
            try
            {
                using (var web = new WebClient())
                {
                    web.Headers["User-Agent"] = "SparkSustain-Updater";
                    web.DownloadFile(url, destination);
                }
                return true;
            }
            catch (Exception e) { Log.Write("Download failed: " + e.Message); return false; }
        }

        public static string Sha256Hex(string path)
        {
            using (var sha = SHA256.Create())
            using (var stream = File.OpenRead(path))
            {
                var hash = sha.ComputeHash(stream);
                var sb = new StringBuilder();
                foreach (var b in hash) sb.Append(b.ToString("x2"));
                return sb.ToString();
            }
        }

        // Copy, verify, extract, recompile, swap, relaunch.
        // Returns an error message, or null when the app is restarting.
        public static string Apply(string url, string sha256)
        {
            string work = Path.Combine(Path.GetTempPath(), "sparksustain-update");
            try { if (Directory.Exists(work)) Directory.Delete(work, true); } catch { }
            Directory.CreateDirectory(work);
            string zip = Path.Combine(work, "update.zip");
            if (!Download(url, zip)) return "Update download failed";
            if (!string.Equals(Sha256Hex(zip), sha256, StringComparison.OrdinalIgnoreCase))
            {
                Log.Write("Update hash mismatch — refusing to install");
                return "Update file failed integrity check — not installed";
            }
            string extracted = Path.Combine(work, "x");
            ZipFile.ExtractToDirectory(zip, extracted);
            // Source may sit at zip root or one folder down.
            string cs = Path.Combine(extracted, "SparkSustain.cs");
            string srcDir = extracted;
            if (!File.Exists(cs))
            {
                foreach (var sub in Directory.EnumerateDirectories(extracted))
                {
                    if (File.Exists(Path.Combine(sub, "SparkSustain.cs")))
                    { srcDir = sub; cs = Path.Combine(sub, "SparkSustain.cs"); break; }
                }
            }
            if (!File.Exists(cs)) return "Update zip contains no SparkSustain.cs";

            string csc = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                @"Microsoft.NET\Framework64\v4.0.30319\csc.exe");
            if (!File.Exists(csc))
                csc = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                    @"Microsoft.NET\Framework\v4.0.30319\csc.exe");
            if (!File.Exists(csc)) return "C# compiler not found — can't build the update";

            string exe = Application.ExecutablePath;
            string newExe = exe + ".new";
            string ico = Path.Combine(srcDir, "SparkSustain.ico");
            string iconArg = File.Exists(ico) ? "/win32icon:\"" + ico + "\" " : "";
            var psi = new ProcessStartInfo();
            psi.FileName = csc;
            psi.Arguments = "/nologo /target:winexe /out:\"" + newExe + "\" " + iconArg +
                "/r:System.dll /r:System.Core.dll /r:System.Drawing.dll " +
                "/r:System.Windows.Forms.dll /r:System.Management.dll " +
                "/r:System.Web.Extensions.dll /r:System.IO.Compression.dll " +
                "/r:System.IO.Compression.FileSystem.dll " +
                "\"" + cs + "\"";
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardError = true;
            psi.RedirectStandardOutput = true;
            using (var p = Process.Start(psi))
            {
                string output = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
                p.WaitForExit(120000);
                if (p.ExitCode != 0 || !File.Exists(newExe))
                {
                    Log.Write("Update compile failed: " + output);
                    return "Update failed to compile — kept the current version";
                }
            }
            // Refresh the manual next to the exe.
            string manual = Path.Combine(srcDir, "Manual.html");
            if (File.Exists(manual))
            {
                try { File.Copy(manual, Path.Combine(Path.GetDirectoryName(exe), "Manual.html"), true); }
                catch { }
            }
            // Swap after this process exits, then relaunch.
            string bat = Path.Combine(work, "swap.bat");
            File.WriteAllText(bat,
                "@echo off\r\n" +
                "ping -n 3 127.0.0.1 >nul\r\n" +
                "move /y \"" + newExe + "\" \"" + exe + "\"\r\n" +
                "start \"\" \"" + exe + "\"\r\n");
            var run = new ProcessStartInfo();
            run.FileName = bat;
            run.UseShellExecute = true;
            run.WindowStyle = ProcessWindowStyle.Hidden;
            Process.Start(run);
            Log.Write("Update staged — restarting");
            return null;
        }
    }

    // ---------------------------------------------------------------- tray app

    public class TrayApp : Form
    {
        readonly NotifyIcon tray = new NotifyIcon();
        readonly VideriClient client = new VideriClient();
        bool automationEnabled = true;
        bool screensAwake = true;
        int lastApplied = -1;            // -1 = nothing sent yet
        bool? lastDeskPowerOK;
        // Manual hold: while set and unexpired, this state beats automation.
        // DateTime.MaxValue = until the user resumes automation.
        DateTime overrideUntil = DateTime.MinValue;
        int overridePercent = 0;
        bool offlineLogged = false;
        string statusLine = "Waiting for first event";
        System.Windows.Forms.Timer pollTimer;
        System.Windows.Forms.Timer enforceTimer;

        const int WM_HOTKEY = 0x0312;
        const int WM_POWERBROADCAST = 0x0218;
        const int PBT_POWERSETTINGCHANGE = 0x8013;
        static Guid GUID_CONSOLE_DISPLAY_STATE = new Guid("6FE69556-704A-47A0-8F24-C28D936FDA47");

        [DllImport("user32.dll")]
        static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint vk);
        [DllImport("user32.dll", SetLastError = true)]
        static extern IntPtr RegisterPowerSettingNotification(IntPtr hRecipient,
            ref Guid PowerSettingGuid, int Flags);

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        struct POWERBROADCAST_SETTING
        {
            public Guid PowerSetting;
            public uint DataLength;
            public byte Data;
        }

        public TrayApp()
        {
            ShowInTaskbar = false;
            WindowState = FormWindowState.Minimized;
            Load += delegate { Hide(); };

            tray.Icon = MakeIcon(true);
            tray.Visible = true;
            tray.Text = "SparkSustain";
            RebuildMenu();

            SystemEvents.PowerModeChanged += OnPowerModeChanged;
            SystemEvents.SessionSwitch += OnSessionSwitch;

            var handle = Handle;   // force handle creation
            RegisterPowerSettingNotification(handle, ref GUID_CONSOLE_DISPLAY_STATE, 0);
            if (!RegisterHotKey(handle, 1, 0x0002 | 0x0001, (uint)Keys.S))  // Ctrl+Alt+S
                Log.Write("Hotkey registration failed");
            else Log.Write("Registered global hotkey Ctrl+Alt+S");

            pollTimer = new System.Windows.Forms.Timer();
            pollTimer.Interval = 3000;
            pollTimer.Tick += delegate { PollTick(); };
            pollTimer.Start();

            enforceTimer = new System.Windows.Forms.Timer();
            enforceTimer.Interval = 600000;
            enforceTimer.Tick += delegate
            {
                var c = Store.Load();
                if (automationEnabled && c != null && c.IsFilledIn())
                    Reconcile("periodic state enforcement", true);
            };
            enforceTimer.Start();

            // Auto-update: check shortly after launch, then every 4 hours.
            var updateTimer = new System.Windows.Forms.Timer();
            updateTimer.Interval = 4 * 3600 * 1000;
            updateTimer.Tick += delegate { CheckForUpdates(false); };
            updateTimer.Start();
            var firstCheck = new System.Windows.Forms.Timer();
            firstCheck.Interval = 60000;
            firstCheck.Tick += delegate { firstCheck.Stop(); CheckForUpdates(false); };
            firstCheck.Start();

            Log.Write("SparkSustain for Windows started (v" + AppInfo.Version + ")");
            var config = Store.Load();
            if (config != null && config.IsFilledIn()) Reconcile("app launch", false);
            else BeginInvoke((MethodInvoker)delegate { RunSetupAssistant(); });
        }

        protected override void SetVisibleCore(bool value)
        {
            base.SetVisibleCore(false);
        }

        // ------------------------------------------------------------- events

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_HOTKEY && m.WParam.ToInt32() == 1)
            {
                bool on = lastApplied > 0;
                Log.Write("Hotkey toggle -> " + (on ? "off" : "on"));
                ManualToggle(!on);
            }
            else if (m.Msg == WM_POWERBROADCAST && m.WParam.ToInt32() == PBT_POWERSETTINGCHANGE)
            {
                try
                {
                    var setting = (POWERBROADCAST_SETTING)Marshal.PtrToStructure(
                        m.LParam, typeof(POWERBROADCAST_SETTING));
                    if (setting.PowerSetting == GUID_CONSOLE_DISPLAY_STATE)
                    {
                        bool awake = setting.Data != 0;   // 0=off, 1=on, 2=dim
                        if (setting.Data != 2 && awake != screensAwake)
                        {
                            screensAwake = awake;
                            Reconcile(awake ? "display on" : "display off", false);
                        }
                    }
                }
                catch { }
            }
            base.WndProc(ref m);
        }

        void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
        {
            if (e.Mode == PowerModes.Suspend)
            {
                screensAwake = false;
                var c = Store.Load();
                if (automationEnabled && c != null && c.IsFilledIn())
                {
                    int percent = DesiredPercent(c);   // a manual hold survives suspend
                    if (lastApplied != percent)
                    {
                        try
                        {
                            client.SetBrightness(c, percent);
                            lastApplied = percent;
                            Log.Write("Applied " + percent + "% before suspend");
                        }
                        catch (Exception ex) { Log.Write("Suspend apply failed: " + ex.Message); }
                    }
                }
            }
            else if (e.Mode == PowerModes.Resume)
            {
                screensAwake = true;
                Reconcile("system resumed", false);
            }
        }

        void OnSessionSwitch(object sender, SessionSwitchEventArgs e)
        {
            if (e.Reason == SessionSwitchReason.SessionLock)
            { screensAwake = false; Reconcile("session locked", false); }
            else if (e.Reason == SessionSwitchReason.SessionUnlock)
            { screensAwake = true; Reconcile("session unlocked", false); }
        }

        void PollTick()
        {
            var c = Store.Load();
            if (c == null || !c.IsFilledIn()) return;
            if (!string.IsNullOrEmpty(c.desk_device_id))
            {
                bool ok = Env.OnDeskPower(c);
                if (lastDeskPowerOK == null || ok != lastDeskPowerOK.Value)
                {
                    lastDeskPowerOK = ok;
                    Log.Write("Desk power " + (ok ? "connected" : "disconnected"));
                }
            }
            if (!automationEnabled) return;
            if (DesiredPercent(c) != lastApplied) Reconcile("power source changed", false);
        }

        // -------------------------------------------------------------- logic

        bool OverrideActive()
        {
            if (overrideUntil > DateTime.Now) return true;
            if (overrideUntil != DateTime.MinValue)
            {
                overrideUntil = DateTime.MinValue;
                Log.Write("Manual hold expired — automation resumed");
            }
            return false;
        }

        string OverrideLabel()
        {
            if (overrideUntil == DateTime.MaxValue) return "until automation resumes";
            return "until " + overrideUntil.ToShortTimeString();
        }

        int DesiredPercent(Config c)
        {
            if (OverrideActive()) return overridePercent;
            return (screensAwake && Env.OnOfficeNetwork(c) && Env.OnDeskPower(c))
                ? c.wake_brightness_percent : c.sleep_brightness_percent;
        }

        void ManualHold(int percent, TimeSpan? span)
        {
            var c = Store.Load();
            if (c == null || !c.IsFilledIn())
            { statusLine = "Setup needed — run the Setup Assistant"; RebuildMenu(); return; }
            overridePercent = percent;
            overrideUntil = span.HasValue ? DateTime.Now.Add(span.Value) : DateTime.MaxValue;
            Log.Write("Manual hold: " + percent + "% " + OverrideLabel());
            lastApplied = -1;
            Reconcile("manual hold", true);
        }

        void ResumeAutomation()
        {
            overrideUntil = DateTime.MinValue;
            Log.Write("Manual hold cleared — automation resumed");
            lastApplied = -1;
            Reconcile("automation resumed", true);
        }

        void ManualToggle(bool toOn)
        {
            var c = Store.Load();
            if (c == null || !c.IsFilledIn())
            { statusLine = "Setup needed — run the Setup Assistant"; RebuildMenu(); return; }
            int percent = toOn ? c.wake_brightness_percent : c.sleep_brightness_percent;
            int minutes = c.default_override_minutes > 0 ? c.default_override_minutes : 60;
            ManualHold(percent, TimeSpan.FromMinutes(minutes));
        }

        static TimeSpan UntilEndOfDay()
        {
            var midnight = DateTime.Today.AddDays(1);
            var span = midnight - DateTime.Now;
            return span.TotalSeconds < 60 ? TimeSpan.FromMinutes(1) : span;
        }

        // Where colleagues get their own copy. Points at the latest release
        // so the link never needs revising per version.
        const string DownloadUrl = "https://github.com/videri-inc/SparkSustain/releases/latest";

        static string InviteText()
        {
            return "SparkSustain keeps the Videri Sparks at your desk in step with your laptop "
                 + "— on at the brightness you pick while you're working there, dark when you're "
                 + "asleep, away, or off your desk power. macOS and Windows, no brightness "
                 + "schedules to maintain.\r\n\r\nDownload: " + DownloadUrl;
        }

        void CopyToClipboard(string text, string confirmation)
        {
            try
            {
                Clipboard.SetText(text);
                statusLine = confirmation;
                Log.Write(confirmation);
            }
            catch (Exception e)
            {
                statusLine = "Couldn't copy to the clipboard";
                Log.Write("Clipboard copy failed: " + e.Message);
            }
            RebuildMenu();
        }

        void CheckForUpdates(bool interactive)
        {
            var c = Store.Load() ?? new Config();
            string url = string.IsNullOrEmpty(c.update_url) ? AppInfo.DefaultUpdateUrl : c.update_url;
            var manifest = Updater.FetchManifest(url);
            if (manifest == null || !manifest.ContainsKey("version"))
            {
                if (interactive) MessageBox.Show(
                    "Couldn't reach the update feed (offline, or the repo is private).",
                    "SparkSustain updates");
                return;
            }
            string latest = Convert.ToString(manifest["version"]);
            if (latest == AppInfo.Version)
            {
                if (interactive) MessageBox.Show("Up to date (v" + AppInfo.Version + ").", "SparkSustain");
                return;
            }
            var win = manifest.ContainsKey("windows") ? manifest["windows"] as Dictionary<string, object> : null;
            if (win == null || !win.ContainsKey("url") || !win.ContainsKey("sha256"))
            {
                if (interactive) MessageBox.Show("Manifest has no Windows entry.", "SparkSustain");
                return;
            }
            Log.Write("Update available: v" + latest + " (running v" + AppInfo.Version + ")");
            statusLine = "Installing v" + latest + "…";
            RebuildMenu();
            string problem = Updater.Apply(Convert.ToString(win["url"]),
                                           Convert.ToString(win["sha256"]));
            if (problem != null)
            {
                statusLine = problem;
                Log.Write("Update failed: " + problem);
                RebuildMenu();
                if (interactive) MessageBox.Show(problem, "SparkSustain update", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            else
            {
                tray.Visible = false;
                Application.Exit();
            }
        }

        // Prove the desk signature tracks presence: power off / unplug ->
        // confirm gone, reconnect -> confirm back. Returns false when the
        // user wants to pick a different device.
        bool VerifyDeskSignature(Config c)
        {
            while (true)
            {
                var r = MessageBox.Show(
                    "Verify your desk signature.\r\n\r\n" +
                    "Power off or unplug your desk source now (monitor, dock, or charger), " +
                    "then click OK so SparkSustain can confirm it notices.\r\n\r\n" +
                    "Cancel skips verification.",
                    "SparkSustain — verify", MessageBoxButtons.OKCancel, MessageBoxIcon.Information);
                if (r != DialogResult.OK) { Log.Write("Desk verification skipped"); return true; }
                if (!Env.OnDeskPower(c)) break;
                var again = MessageBox.Show(
                    "SparkSustain STILL detects your desk source.\r\n\r\n" +
                    "If you really powered it off, the chosen device doesn't reflect power " +
                    "state — HDMI/DisplayPort monitor entries often stay visible when the " +
                    "screen is off. A USB device belonging to your dock or monitor is the " +
                    "most reliable anchor.\r\n\r\n" +
                    "Retry = check again.   Abort = pick a different device.   Ignore = keep anyway.",
                    "Not detected", MessageBoxButtons.AbortRetryIgnore, MessageBoxIcon.Warning);
                if (again == DialogResult.Abort) return false;
                if (again == DialogResult.Ignore)
                { Log.Write("Desk verification overridden (disconnect not detected)"); return true; }
            }
            Log.Write("Desk verification: disconnect detected");
            while (true)
            {
                var r = MessageBox.Show(
                    "Now reconnect / power your desk source back on, then click OK.",
                    "SparkSustain — verify", MessageBoxButtons.OKCancel, MessageBoxIcon.Information);
                if (r != DialogResult.OK) return true;
                if (Env.OnDeskPower(c))
                {
                    Log.Write("Desk verification: reconnect detected — signature verified");
                    MessageBox.Show(
                        "Verified. SparkSustain reliably detects when you're at your desk — " +
                        "disconnecting this source darkens your Sparks within a few seconds.",
                        "SparkSustain", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return true;
                }
            }
        }

        void Reconcile(string reason, bool force)
        {
            if (!automationEnabled) { Log.Write("Automation paused — ignoring " + reason); return; }
            var c = Store.Load();
            if (c == null || !c.IsFilledIn())
            {
                statusLine = "Setup needed — run the Setup Assistant";
                RebuildMenu();
                return;
            }
            int percent = DesiredPercent(c);
            tray.Icon = MakeIcon(percent > 0);
            if (!force && lastApplied == percent) { RebuildMenu(); return; }
            if (!NetworkInterface.GetIsNetworkAvailable())
            {
                if (!offlineLogged)
                {
                    offlineLogged = true;
                    Log.Write("Offline — holding " + percent + "% until the network returns (" + reason + ")");
                }
                statusLine = "Offline — will sync when the network returns";
                RebuildMenu();
                return;
            }
            offlineLogged = false;
            statusLine = "Applying " + percent + "%…";
            RebuildMenu();
            ThreadPool.QueueUserWorkItem(delegate
            {
                try
                {
                    string message = client.SetBrightness(c, percent);
                    lastApplied = percent;
                    statusLine = message + " (" + reason + ")";
                }
                catch (Exception e)
                {
                    statusLine = "Failed: " + e.Message;
                    Log.Write("reconcile error (" + reason + "): " + e.Message);
                }
                BeginInvoke((MethodInvoker)RebuildMenu);
            });
        }


        // ------------------------------------------------------------- wizard

        void RunSetupAssistant()
        {
            var c = Store.Load() ?? new Config();

            // API key hand-holding
            while (true)
            {
                var choice = MessageBox.Show(
                    "SparkSustain makes the Sparks near your desk follow this PC: awake at " +
                    "the office = screens on; asleep or away = screens dark.\r\n\r\n" +
                    "You need a Videri developer API key. Get it at " +
                    "developer.videri.com/dashboard (API Keys tab) — copy it right away, " +
                    "it's shown only once.\r\n\r\n" +
                    "Open the API keys page now? (No = I already have my key)",
                    "Set up SparkSustain", MessageBoxButtons.YesNoCancel,
                    MessageBoxIcon.Information);
                if (choice == DialogResult.Cancel) return;
                if (choice == DialogResult.Yes)
                { Process.Start("https://developer.videri.com/dashboard"); continue; }
                break;
            }

            // credentials, validated live
            while (true)
            {
                using (var form = new CredentialsForm(c))
                {
                    if (form.ShowDialog() != DialogResult.OK) return;
                    c.username = form.UserBox.Text.Trim();
                    c.password = form.PassBox.Text;
                    c.api_key = form.KeyBox.Text.Trim();
                }
                if (!c.HasCredentials()) continue;
                try { client.ValidateCredentials(c); Store.Save(c); break; }
                catch (Exception e)
                {
                    MessageBox.Show(e.Message, "Couldn't sign in",
                        MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
            }

            // choose workspaces + sub-workspaces (scopes visibility and control)
            try
            {
                var all = client.AllTokenTenants(c);
                var forest = new Dictionary<string, List<VideriClient.GroupNode>>();
                foreach (var tenant in all)
                {
                    List<VideriClient.GroupNode> tenantTree;
                    try { tenantTree = client.FetchGroupTree(c, tenant); }
                    catch { tenantTree = new List<VideriClient.GroupNode>(); }
                    forest[tenant] = tenantTree;
                }
                bool trivial = all.Count == 1 && forest[all[0]].Count == 0;
                if (trivial)
                {
                    c.workspaces = all;
                    c.workspace_groups = new Dictionary<string, List<string>>();
                    Store.Save(c);
                }
                else
                {
                    var preTenants = new HashSet<string>();
                    foreach (var w in c.workspaces ?? new List<string>())
                    {
                        List<string> g;
                        if (c.workspace_groups == null
                            || !c.workspace_groups.TryGetValue(w, out g)
                            || g == null || g.Count == 0)
                            preTenants.Add(w);
                    }
                    var preGroups = new HashSet<string>();
                    if (c.workspace_groups != null)
                        foreach (var pair in c.workspace_groups)
                            foreach (var uuid in pair.Value ?? new List<string>())
                                preGroups.Add(uuid);
                    while (true)
                    {
                        using (var form = new WorkspaceTreeForm(forest, preTenants, preGroups))
                        {
                            if (form.ShowDialog() != DialogResult.OK) return;
                            if (!form.HasAnySelection())
                            {
                                MessageBox.Show(
                                    "Check at least one workspace or sub-workspace to continue.",
                                    "SparkSustain");
                                continue;
                            }
                            var selection = form.Selection();
                            c.workspaces = selection.Keys.ToList();
                            c.workspace_groups = selection;
                            Store.Save(c);
                            Log.Write("Workspaces scoped to " + string.Join(", ",
                                selection.Select(p => p.Value.Count == 0
                                    ? p.Key : p.Key + " (" + p.Value.Count + " sub-workspaces)")));
                            break;
                        }
                    }
                }
            }
            catch (Exception e) { Log.Write("Workspace tree error: " + e.Message); }

            // pick Sparks
            List<CanvasTarget> found;
            List<string> labels;
            try { found = client.FetchCanvases(c, out labels); }
            catch (Exception e)
            {
                MessageBox.Show("Couldn't load your canvases: " + e.Message +
                    "\r\n\r\nYour credentials are saved — run the Setup Assistant again to finish.",
                    "SparkSustain", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            var preselected = new HashSet<string>(c.canvases.Select(t => t.device_jid));
            while (true)
            {
                using (var picker = new PickerForm(found, labels, preselected))
                {
                    if (picker.ShowDialog() != DialogResult.OK) return;
                    var selected = picker.Selected();
                    if (selected.Count == 0)
                    {
                        MessageBox.Show("Check at least one Spark to continue.", "SparkSustain");
                        continue;
                    }
                    c.canvases = selected;
                    c.schedules_overridden_asked = false;
                    Store.Save(c);
                    break;
                }
            }

            // schedule takeover warning + baseline off
            OfferScheduleOverride(c);

            // office network
            var prefixes = Env.LocalIPv4().Select(Env.SubnetPrefix)
                .Where(p => p != null).Distinct().OrderBy(p => p).ToList();
            if (prefixes.Count > 0)
            {
                var answer = MessageBox.Show(
                    "Are you at the office right now?\r\n\r\nSparkSustain will remember this " +
                    "network (" + string.Join(", ", prefixes) + "*) as the office. Brightness " +
                    "only comes up when this PC is on it.\r\n\r\nNot at the office? Choose No " +
                    "and use \"Set Current Network as Office\" from the tray menu at your desk.",
                    "Office network", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                if (answer == DialogResult.Yes)
                {
                    c.office_network_prefixes = prefixes;
                    Store.Save(c);
                }
            }

            // desk power / dock
            while (true)
            {
                if (Env.OnACPower())
                {
                    var answer = MessageBox.Show(
                        "Require your desk power/dock?\r\n\r\nPick the USB-C dock or monitor " +
                        "that means \"I'm at my desk.\" Your Sparks then only light up while " +
                        "this PC is on AC power with that device connected — on battery or a " +
                        "different charger they stay dark.\r\n\r\nYes = pick the device now. " +
                        "No = decide later from the tray menu.",
                        "Desk power source", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                    if (answer == DialogResult.Yes)
                    {
                        while (true)
                        {
                            using (var devices = new DevicePickerForm(Env.PresentDevices()))
                            {
                                if (devices.ShowDialog() != DialogResult.OK || devices.Chosen() == null)
                                    break;
                                var device = devices.Chosen().Value;
                                c.desk_device_name = device.Key;
                                c.desk_device_id = device.Value;
                                Store.Save(c);
                                Log.Write("Desk device set: " + device.Key);
                            }
                            if (VerifyDeskSignature(c)) break;
                            // user chose to pick a different device
                            c.desk_device_name = ""; c.desk_device_id = "";
                            Store.Save(c);
                        }
                    }
                    break;
                }
                var retry = MessageBox.Show(
                    "No external power detected. Connect your desk power source and choose " +
                    "Retry — or Cancel to decide later from the tray menu.",
                    "Desk power source", MessageBoxButtons.RetryCancel, MessageBoxIcon.Information);
                if (retry != DialogResult.Retry) break;
            }

            // start with Windows + first sync
            SetStartup(true);
            MessageBox.Show("You're set. SparkSustain starts with Windows and will sync " +
                "your Sparks now.", "SparkSustain", MessageBoxButtons.OK,
                MessageBoxIcon.Information);
            lastApplied = -1;
            Reconcile("setup finished", false);
        }

        void OfferScheduleOverride(Config c)
        {
            int count = c.ReadyTargets().Count;
            var answer = MessageBox.Show(
                "SparkSustain will take over brightness control.\r\n\r\n" +
                "Any existing brightness schedules on the " + count + " display(s) it manages " +
                "will be permanently DELETED from the Videri platform, so they can't fight " +
                "SparkSustain's on/off control. This cannot be undone.\r\n\r\n" +
                "The displays will then default to 0% brightness / display off, and only " +
                "light up while this PC meets the wake conditions.\r\n\r\n" +
                "Other displays are not affected. Delete the schedules?",
                "Brightness schedule takeover", MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning);
            c.schedules_overridden_asked = true;
            Store.Save(c);
            if (answer != DialogResult.Yes)
            {
                Log.Write("Schedule takeover declined — schedules may override SparkSustain");
                return;
            }
            try
            {
                string message = client.DeleteBrightnessSchedules(c);
                Log.Write("Schedule override: " + message);
                client.SetBrightness(c, c.sleep_brightness_percent);
                lastApplied = c.sleep_brightness_percent;
                Log.Write("Takeover baseline applied: managed displays defaulted to 0%/off");
            }
            catch (Exception e) { Log.Write("Schedule takeover error: " + e.Message); }
        }

        // --------------------------------------------------------------- menu

        void RebuildMenu()
        {
            var c = Store.Load() ?? new Config();
            var menu = new ContextMenuStrip();

            var status = new ToolStripMenuItem(statusLine); status.Enabled = false;
            menu.Items.Add(status);

            string net = (c.office_network_prefixes != null && c.office_network_prefixes.Count > 0)
                ? "Office network: " + string.Join(", ", c.office_network_prefixes) + "* ("
                    + (Env.OnOfficeNetwork(c) ? "connected" : "away") + ")"
                : "Office network: not set (automating everywhere)";
            var netItem = new ToolStripMenuItem(net); netItem.Enabled = false;
            menu.Items.Add(netItem);

            string power = string.IsNullOrEmpty(c.desk_device_id)
                ? "Desk power: not required"
                : "Desk power: " + c.desk_device_name + " ("
                    + (Env.OnDeskPower(c) ? "connected" : "not connected") + ")";
            var powerItem = new ToolStripMenuItem(power); powerItem.Enabled = false;
            menu.Items.Add(powerItem);
            menu.Items.Add(new ToolStripSeparator());

            var auto = new ToolStripMenuItem("Automation Enabled");
            auto.Checked = automationEnabled;
            auto.Click += delegate
            {
                automationEnabled = !automationEnabled;
                statusLine = automationEnabled ? "Automation resumed" : "Automation paused";
                Log.Write(statusLine);
                RebuildMenu();
                if (automationEnabled) Reconcile("automation resumed", false);
            };
            menu.Items.Add(auto);
            menu.Items.Add(new ToolStripSeparator());

            if (overrideUntil > DateTime.Now)
            {
                var holdStatus = new ToolStripMenuItem(
                    "Manual hold: " + overridePercent + "% " + OverrideLabel());
                holdStatus.Enabled = false;
                menu.Items.Add(holdStatus);
                menu.Items.Add("Resume Automation Now", null, delegate { ResumeAutomation(); });
                menu.Items.Add(new ToolStripSeparator());
            }

            // Manual holds: pin a state for a chosen time; automation enforces
            // the hold, then takes back over when it expires.
            Func<string, int, ToolStripMenuItem> holdMenu = delegate(string title, int percent)
            {
                var parent = new ToolStripMenuItem(title);
                Action<string, Func<TimeSpan?>> add = delegate(string label, Func<TimeSpan?> span)
                {
                    parent.DropDownItems.Add(label, null,
                        delegate { ManualHold(percent, span()); });
                };
                add("For 30 Minutes", delegate { return (TimeSpan?)TimeSpan.FromMinutes(30); });
                add("For 1 Hour", delegate { return (TimeSpan?)TimeSpan.FromHours(1); });
                add("For 2 Hours", delegate { return (TimeSpan?)TimeSpan.FromHours(2); });
                add("Until End of Day", delegate { return (TimeSpan?)UntilEndOfDay(); });
                add("Until Automation Resumes", delegate { return (TimeSpan?)null; });
                return parent;
            };
            menu.Items.Add(holdMenu("Hold Wake Brightness (" + c.wake_brightness_percent + "%)",
                c.wake_brightness_percent));
            menu.Items.Add(holdMenu("Hold Screens Off (" + c.sleep_brightness_percent + "%)",
                c.sleep_brightness_percent));

            var wakeLevel = new ToolStripMenuItem("Wake Brightness");
            for (int p = 10; p <= 100; p += 10)
            {
                int percent = p;
                var item = new ToolStripMenuItem(percent + "%");
                item.Checked = percent == c.wake_brightness_percent;
                item.Click += delegate
                {
                    var cfg = Store.Load(); if (cfg == null) return;
                    cfg.wake_brightness_percent = percent;
                    Store.Save(cfg);
                    Log.Write("Wake brightness set to " + percent + "%");
                    lastApplied = -1;
                    Reconcile("wake brightness changed", false);
                };
                wakeLevel.DropDownItems.Add(item);
            }
            menu.Items.Add(wakeLevel);

            var hint = new ToolStripMenuItem("Toggle Sparks anywhere: Ctrl+Alt+S");
            hint.Enabled = false;
            menu.Items.Add(hint);
            menu.Items.Add(new ToolStripSeparator());

            menu.Items.Add("Run Setup Assistant…", null, delegate { RunSetupAssistant(); });
            menu.Items.Add("Set Current Network as Office", null, delegate
            {
                var cfg = Store.Load(); if (cfg == null) return;
                var prefixes = Env.LocalIPv4().Select(Env.SubnetPrefix)
                    .Where(p => p != null).Distinct().OrderBy(p => p).ToList();
                if (prefixes.Count == 0)
                { statusLine = "No active network found"; RebuildMenu(); return; }
                cfg.office_network_prefixes = prefixes;
                Store.Save(cfg);
                statusLine = "Office network set to " + string.Join(", ", prefixes) + "*";
                Log.Write(statusLine);
                RebuildMenu();
                Reconcile("office network captured", false);
            });
            menu.Items.Add(string.IsNullOrEmpty(c.desk_device_id)
                ? "Require Desk Power/Dock…" : "Stop Requiring Desk Power", null, delegate
            {
                var cfg = Store.Load(); if (cfg == null) return;
                if (!string.IsNullOrEmpty(cfg.desk_device_id))
                {
                    cfg.desk_device_id = ""; cfg.desk_device_name = "";
                    Store.Save(cfg);
                    statusLine = "Desk power requirement cleared";
                }
                else
                {
                    while (true)
                    {
                        using (var devices = new DevicePickerForm(Env.PresentDevices()))
                        {
                            if (devices.ShowDialog() != DialogResult.OK || devices.Chosen() == null)
                                break;
                            var device = devices.Chosen().Value;
                            cfg.desk_device_name = device.Key;
                            cfg.desk_device_id = device.Value;
                            Store.Save(cfg);
                            statusLine = "Desk device set: " + device.Key;
                        }
                        if (VerifyDeskSignature(cfg)) break;
                        cfg.desk_device_name = ""; cfg.desk_device_id = "";
                        Store.Save(cfg);
                    }
                }
                Log.Write(statusLine);
                RebuildMenu();
                Reconcile("desk power requirement changed", false);
            });
            var versionItem = new ToolStripMenuItem("SparkSustain v" + AppInfo.Version);
            versionItem.Enabled = false;
            menu.Items.Add(versionItem);
            menu.Items.Add("Check for Updates Now", null, delegate { CheckForUpdates(true); });
            var share = new ToolStripMenuItem("Share SparkSustain");
            share.DropDownItems.Add("Copy Invite Message", null, delegate
            {
                CopyToClipboard(InviteText(), "Invite message copied — paste it anywhere");
            });
            share.DropDownItems.Add("Copy Download Link", null, delegate
            {
                CopyToClipboard(DownloadUrl, "Download link copied");
            });
            share.DropDownItems.Add("Open Download Page", null, delegate
            {
                try { Process.Start(DownloadUrl); } catch (Exception e) { Log.Write("Share open failed: " + e.Message); }
            });
            menu.Items.Add(share);
            menu.Items.Add("Help", null, delegate
            {
                string manual = Path.Combine(
                    Path.GetDirectoryName(Application.ExecutablePath), "Manual.html");
                if (File.Exists(manual)) Process.Start(manual);
                else { statusLine = "Manual.html not found next to the app"; RebuildMenu(); }
            });
            menu.Items.Add("View Log", null, delegate
            {
                if (!File.Exists(Paths.LogFile)) File.WriteAllText(Paths.LogFile, "");
                Process.Start("notepad.exe", Paths.LogFile);
            });
            menu.Items.Add(new ToolStripSeparator());

            var startup = new ToolStripMenuItem("Start with Windows");
            startup.Checked = StartupEnabled();
            startup.Click += delegate { SetStartup(!StartupEnabled()); RebuildMenu(); };
            menu.Items.Add(startup);
            menu.Items.Add(new ToolStripSeparator());

            menu.Items.Add("Quit SparkSustain", null, delegate
            {
                tray.Visible = false;
                Application.Exit();
            });

            tray.ContextMenuStrip = menu;
        }

        // ------------------------------------------------------------- helpers

        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

        bool StartupEnabled()
        {
            using (var key = Registry.CurrentUser.OpenSubKey(RunKey))
                return key != null && key.GetValue("SparkSustain") != null;
        }

        void SetStartup(bool enable)
        {
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(RunKey, true))
                {
                    if (enable) key.SetValue("SparkSustain",
                        "\"" + Application.ExecutablePath + "\"");
                    else key.DeleteValue("SparkSustain", false);
                }
            }
            catch (Exception e) { Log.Write("Startup toggle failed: " + e.Message); }
        }

        // The Videri V mark, matching the app icon: amber when the Sparks are
        // lit, slate when they're dark. (GDI+ y grows downward.)
        Icon MakeIcon(bool on)
        {
            var bmp = new Bitmap(16, 16);
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);
                var color = on ? Color.FromArgb(242, 169, 59) : Color.FromArgb(128, 140, 158);
                using (var pen = new Pen(color, 3.0f))
                {
                    pen.StartCap = System.Drawing.Drawing2D.LineCap.Round;
                    pen.EndCap = System.Drawing.Drawing2D.LineCap.Round;
                    g.DrawLine(pen, 3.0f, 2.8f, 8.3f, 13.0f);
                }
                using (var brush = new SolidBrush(color))
                    g.FillEllipse(brush, 10.7f, 1.9f, 3.8f, 3.8f);
            }
            return Icon.FromHandle(bmp.GetHicon());
        }

        [STAThread]
        public static void Main()
        {
            bool created;
            using (var mutex = new Mutex(true, "SparkSustainSingleton", out created))
            {
                if (!created) return;
                Application.EnableVisualStyles();
                Application.Run(new TrayApp());
            }
        }
    }
}
