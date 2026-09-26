namespace KCDMP_launcher.Models
{
    // The two agent endpoints' payloads (moved here from AppModels.cs so the
    // agent test project can compile this file on its own, WO-129).
    // WO-127: mirrors AgentConnectionStatus.Json (dotnet/KcdMp.Client/ConnectionTools.cs).
    public class ConnectionStatusData
    {
        public string State { get; set; } = "";
        public string Via { get; set; } = "direct";
        public string Kind { get; set; } = "None";
        public string Message { get; set; } = "";
        public string Next { get; set; } = "";
        public bool Fatal { get; set; }
        public int Failures { get; set; }
    }

    // Mirrors GameBridge.JoinStatusJson (dotnet/KcdMp.Client/GameBridge.Wo123.cs, WO-123).
    public class JoinStatusData
    {
        public string State { get; set; } = "idle";
        public double Percent { get; set; }
        public long Bytes { get; set; }
        public long Total { get; set; }
        public double EtaS { get; set; }
        public string Message { get; set; } = "";
    }

    /// <summary>
    /// WO-129: what the launcher shows about its session agent, from the two
    /// endpoints the agent publishes for its whole life (/connection-status,
    /// /join-status). Pure logic, one call per poll, so it can be tested.
    ///
    /// The first two-player session: "Connecting to your host..." stayed on
    /// both machines after they connected, and the joiner never saw the "Bring
    /// my character" / "Start fresh" buttons although its agent had asked for
    /// them -- and neither launcher log said what the launcher had read. So:
    /// the line follows the agent's state and clears once connected; an
    /// unreadable agent is said so after <see cref="UnreadableAfterS"/>, never
    /// shown as a frozen "connecting"; and every change is reported once
    /// (<see cref="Apply"/> returns the log line) for the launcher log.
    /// </summary>
    public sealed class AgentStatusBanner
    {
        public const double UnreadableAfterS = 8.0;

        public string ConnLine { get; private set; } = "";
        public bool ConnBad { get; private set; }
        public string JoinMessage { get; private set; } = "";
        public string JoinState { get; private set; } = "idle";
        /// <summary>True while the agent asks the player for the first-join choice.</summary>
        public bool ShowChoiceButtons => JoinState == "choose";

        private string _lastConnState = "";
        private double _lastReadAt = double.NaN;
        private string _lastLog = "";

        /// <summary>The agent was (re)started: "connecting" until it says otherwise.</summary>
        public void Start(bool viaSteam, double nowS)
        {
            ConnLine = viaSteam ? "Connecting to your host through Steam..." : "Connecting to your host...";
            ConnBad = false;
            JoinMessage = ""; JoinState = "idle";
            _lastConnState = "starting";
            _lastReadAt = nowS;
            _lastLog = "";
        }

        /// <summary>
        /// One poll. <paramref name="cs"/> / <paramref name="js"/> are null when
        /// the endpoint could not be read. Returns a line for the launcher log
        /// when anything visible changed, else null.
        /// </summary>
        public string? Apply(ConnectionStatusData? cs, JoinStatusData? js, bool agentAlive, double nowS)
        {
            if (!agentAlive)
            {
                ConnLine = _lastConnState == "connected" || _lastConnState == "" ? "" : "The multiplayer part stopped. Click CONNECT to start it again.";
                ConnBad = ConnLine.Length > 0;
                JoinMessage = ""; JoinState = "idle";
                return Report("agent=exited");
            }
            if (cs is not null)
            {
                _lastReadAt = nowS;
                _lastConnState = cs.State;
                switch (cs.State)
                {
                    case "connected": ConnLine = ""; ConnBad = false; break;
                    case "failed": ConnLine = (cs.Message + " " + cs.Next).Trim(); ConnBad = true; break;
                    default: ConnLine = cs.Message; ConnBad = false; break;
                }
            }
            else if (!double.IsNaN(_lastReadAt) && nowS - _lastReadAt >= UnreadableAfterS && _lastConnState != "connected")
            {
                ConnLine = "The multiplayer part isn't answering the launcher. If this stays, send the logs with Report a bug.";
                ConnBad = true;
            }
            if (js is not null)
            {
                JoinState = string.IsNullOrEmpty(js.State) ? "idle" : js.State;
                JoinMessage = JoinState == "idle" ? "" : js.Message;
            }
            return Report($"connection={(cs?.State ?? "unread")} join={(js is null ? "unread" : JoinState)}");
        }

        private string? Report(string what)
        {
            string line = $"Agent status: {what} line=\"{ConnLine}\" join=\"{JoinMessage}\" buttons={(ShowChoiceButtons ? "shown" : "hidden")}";
            if (line == _lastLog) return null;
            _lastLog = line;
            return line;
        }
    }
}
