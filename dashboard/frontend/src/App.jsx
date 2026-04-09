import { useState, useEffect, useCallback } from "react";

const REFRESH_INTERVAL = 30000;

function timeAgo(dateString) {
  if (!dateString) return "Unknown";
  const now = new Date();
  const past = new Date(dateString);
  const seconds = Math.floor((now - past) / 1000);

  if (seconds < 60) return "just now";
  if (seconds < 3600) {
    const m = Math.floor(seconds / 60);
    return `${m} minute${m !== 1 ? "s" : ""} ago`;
  }
  if (seconds < 86400) {
    const h = Math.floor(seconds / 3600);
    return `${h} hour${h !== 1 ? "s" : ""} ago`;
  }
  const d = Math.floor(seconds / 86400);
  return `${d} day${d !== 1 ? "s" : ""} ago`;
}

function StatusBadge({ status }) {
  const normalized = (status || "").toLowerCase();
  let className = "badge badge-unknown";
  if (normalized === "ready" || normalized === "active") {
    className = "badge badge-ready";
  } else if (
    normalized === "deploying" ||
    normalized === "pending" ||
    normalized === "provisioning"
  ) {
    className = "badge badge-pending";
  } else if (normalized === "failed" || normalized === "error") {
    className = "badge badge-error";
  }
  return <span className={className}>{status || "Unknown"}</span>;
}

function groupByApp(services) {
  const groups = {};
  for (const svc of services) {
    const app = svc.app || svc.name || "unknown";
    if (!groups[app]) groups[app] = [];
    groups[app].push(svc);
  }
  return Object.entries(groups).sort(([a], [b]) => a.localeCompare(b));
}

export default function App() {
  const [services, setServices] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [lastRefresh, setLastRefresh] = useState(null);

  const fetchServices = useCallback(async () => {
    try {
      const res = await fetch("/api/services");
      if (!res.ok) throw new Error(`HTTP ${res.status}: ${res.statusText}`);
      const data = await res.json();
      setServices(Array.isArray(data) ? data : data.services || []);
      setError(null);
      setLastRefresh(new Date());
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchServices();
    const interval = setInterval(fetchServices, REFRESH_INTERVAL);
    return () => clearInterval(interval);
  }, [fetchServices]);

  const totalServices = services.length;
  const grouped = groupByApp(services);
  const totalApps = grouped.length;
  const healthyCount = services.filter((s) => {
    const st = (s.status || "").toLowerCase();
    return st === "ready" || st === "active";
  }).length;

  if (loading) {
    return (
      <div className="container">
        <Header />
        <div className="loading">
          <div className="spinner" />
          <p>Loading services...</p>
        </div>
      </div>
    );
  }

  return (
    <div className="container">
      <Header />

      {error && (
        <div className="error-banner">
          <span>Failed to fetch services: {error}</span>
          <button onClick={fetchServices}>Retry</button>
        </div>
      )}

      <div className="stats">
        <div className="stat-card">
          <div className="stat-value">{totalApps}</div>
          <div className="stat-label">Apps</div>
        </div>
        <div className="stat-card">
          <div className="stat-value">{totalServices}</div>
          <div className="stat-label">Services</div>
        </div>
        <div className="stat-card">
          <div className="stat-value stat-healthy">{healthyCount}</div>
          <div className="stat-label">Healthy</div>
        </div>
        <div className="stat-card">
          <div className="stat-value stat-unhealthy">
            {totalServices - healthyCount}
          </div>
          <div className="stat-label">Unhealthy</div>
        </div>
      </div>

      {grouped.length === 0 && !error ? (
        <div className="empty">No services found.</div>
      ) : (
        grouped.map(([appName, appServices]) => (
          <div key={appName} className="app-group">
            <h2 className="app-name">{appName}</h2>
            <div className="table-wrapper">
              <table>
                <thead>
                  <tr>
                    <th>Environment</th>
                    <th>Status</th>
                    <th>Revision</th>
                    <th>Last Deployed</th>
                    <th>URL</th>
                  </tr>
                </thead>
                <tbody>
                  {appServices.map((svc, i) => (
                    <tr key={svc.name + svc.environment + i}>
                      <td>
                        <span
                          className={`env-tag env-${(svc.environment || "unknown").toLowerCase()}`}
                        >
                          {svc.environment || "unknown"}
                        </span>
                      </td>
                      <td>
                        <StatusBadge status={svc.status} />
                      </td>
                      <td className="mono">{svc.revision || "-"}</td>
                      <td title={svc.lastDeployed}>
                        {timeAgo(svc.lastDeployed)}
                      </td>
                      <td>
                        {svc.customDomain ? (
                          <a
                            href={`https://${svc.customDomain}`}
                            target="_blank"
                            rel="noopener noreferrer"
                          >
                            {svc.customDomain}
                          </a>
                        ) : svc.url ? (
                          <a
                            href={svc.url}
                            target="_blank"
                            rel="noopener noreferrer"
                            style={{ opacity: 0.6 }}
                          >
                            {svc.url.replace(/^https?:\/\//, "")}
                          </a>
                        ) : (
                          "-"
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        ))
      )}

      {lastRefresh && (
        <div className="footer">
          Last refreshed: {lastRefresh.toLocaleTimeString()} &middot;
          Auto-refreshes every 30s
        </div>
      )}
    </div>
  );
}

function Header() {
  return (
    <header className="header">
      <h1>
        <span role="img" aria-label="rocket">
          🚀
        </span>{" "}
        StackRamp Dashboard
      </h1>
    </header>
  );
}
