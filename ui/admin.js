(() => {
  function showStatus(form, message, isError) {
    let status = form.querySelector(".upload-status");
    if (!status) {
      status = document.createElement("div");
      status.className = "upload-status mt-2 small";
      form.appendChild(status);
    }
    status.className = "upload-status mt-2 small " + (isError ? "text-danger" : "text-success");
    status.textContent = message;
  }

  document.addEventListener("click", (event) => {
    const opener = event.target.closest("[data-dialog-open]");
    if (opener) {
      const dialog = document.getElementById(opener.dataset.dialogOpen);
      if (dialog && typeof dialog.showModal === "function") dialog.showModal();
      return;
    }
    const closer = event.target.closest("[data-dialog-close]");
    if (closer) {
      const dialog = closer.closest("dialog");
      if (dialog) dialog.close();
    }
  });

  async function uploadRaw(form, endpoint) {
    const fileInput = form.querySelector('input[type="file"]');
    const file = fileInput && fileInput.files && fileInput.files[0];
    if (!file) {
      showStatus(form, "Choose a bundle first.", true);
      return;
    }
    const button = form.querySelector('button[type="submit"]');
    if (button) button.disabled = true;
    showStatus(form, "Importing and validating…", false);
    try {
      const response = await fetch(endpoint, {
        method: "POST",
        headers: {"Content-Type": "application/octet-stream"},
        body: file
      });
      const text = await response.text();
      if (!response.ok) throw new Error(text || "Import failed.");
      showStatus(form, text || "Import complete.", false);
      window.location.assign(form.dataset.redirect || "/");
    } catch (error) {
      showStatus(form, error.message || String(error), true);
    } finally {
      if (button) button.disabled = false;
    }
  }

  const ruleSearch = document.getElementById("crsRuleSearch");
  if (ruleSearch) {
    ruleSearch.addEventListener("input", () => {
      const term = ruleSearch.value.trim().toLowerCase();
      document.querySelectorAll("[data-rule-row]").forEach((row) => {
        const haystack = (row.dataset.ruleSearch || row.textContent || "").toLowerCase();
        row.hidden = term !== "" && !haystack.includes(term);
      });
    });
  }

  document.addEventListener("submit", async (event) => {
    const siteForm = event.target.closest(".bundle-import-form");
    if (siteForm) {
      event.preventDefault();
      const params = new URLSearchParams();
      const certBox = siteForm.querySelector('input[name="certificates"]');
      params.set("certificates", certBox && certBox.checked ? "1" : "0");
      // Site imports must identify the expected site, not auto-detect an all-sites bundle.
      if (siteForm.dataset.scope) params.set("scope", siteForm.dataset.scope);
      if (siteForm.dataset.host) params.set("host", siteForm.dataset.host);
      await uploadRaw(siteForm, "/admin/import?" + params.toString());
      return;
    }

    const wafForm = event.target.closest(".waf-import-form");
    if (wafForm) {
      event.preventDefault();
      await uploadRaw(wafForm, "/admin/owasp/import");
    }

    const crsForm = event.target.closest(".crs-import-form");
    if (crsForm) {
      event.preventDefault();
      await uploadRaw(crsForm, "/admin/owasp/crs/import");
    }
  });
})();
// Preserve filter and collector selections across full-page form submissions.
(() => {
  if (typeof location === "undefined" || typeof URLSearchParams === "undefined" ||
      typeof document === "undefined" || typeof document.querySelectorAll !== "function") return;
  const params = new URLSearchParams(location.search);
  document.querySelectorAll('form[action="/admin/logs"] select[name]').forEach((select) => {
    const value = params.get(select.name);
    if (value !== null && Array.from(select.options).some((option) => option.value === value)) select.value = value;
  });
  document.querySelectorAll('select[data-selected]').forEach((select) => {
    const value = select.getAttribute('data-selected');
    if (Array.from(select.options).some((option) => option.value === value)) select.value = value;
  });
})();

// Alerts: searchable inventory-backed host/alias + route selectors. No inline JS.
(() => {
  if (typeof document === "undefined" || typeof document.getElementById !== "function") return;
  const form = document.getElementById("alertRuleForm");
  if (!form) return;
  const hostChecks = Array.from(form.querySelectorAll("[data-alert-host]"));
  const routeChecks = Array.from(form.querySelectorAll("[data-alert-route]"));
  const hostButton = document.getElementById("alertHostButton");
  const routeButton = document.getElementById("alertRouteButton");
  const hostOptions = document.getElementById("alertHostOptions");
  const routeOptions = document.getElementById("alertRouteOptions");
  const scopesField = form.querySelector('input[name="scopes_json"]');
  const checked = (items) => items.filter((item) => item.checked);
  const shorten = (values, fallback) => {
    if (!values.length) return fallback;
    return values.length <= 2 ? values.join(", ") : `${values.length} selected`;
  };
  const hideMenu = (button, menu) => {
    menu.hidden = true;
    button.setAttribute("aria-expanded", "false");
  };
  function updatePickers() {
    const selectedHosts = checked(hostChecks);
    const selectedSites = new Set(selectedHosts.map((item) => item.dataset.site));
    routeChecks.forEach((item) => {
      const available = selectedSites.has(item.dataset.site);
      item.closest("[data-alert-route-item]").hidden = !available;
      if (!available) item.checked = false;
    });
    hostButton.textContent = shorten(selectedHosts.map((item) => item.value), "All hosts (select to restrict)");
    routeButton.disabled = selectedHosts.length === 0 || !routeChecks.some((item) => !item.closest("[data-alert-route-item]").hidden);
    const selectedRoutes = checked(routeChecks);
    routeButton.textContent = routeButton.disabled ?
      (selectedHosts.length ? "No routes configured for these hosts" : "Select hosts first") :
      shorten(selectedRoutes.map((item) => `${item.dataset.site} · ${item.value}`), "All routes (select to restrict)");
    if (routeButton.disabled) hideMenu(routeButton, routeOptions);
    const scopes = selectedHosts.map((item) => ({
      host: item.value,
      site: item.dataset.site,
      routes: selectedRoutes.filter((route) => route.dataset.site === item.dataset.site).map((route) => route.value)
    }));
    scopesField.value = JSON.stringify(scopes);
  }
  hostChecks.forEach((item) => item.addEventListener("change", updatePickers));
  routeChecks.forEach((item) => item.addEventListener("change", updatePickers));
  document.addEventListener("click", (event) => {
    const toggle = event.target.closest("[data-alert-toggle]");
    if (toggle && !toggle.disabled) {
      const menu = toggle.dataset.alertToggle === "hosts" ? hostOptions : routeOptions;
      const otherButton = toggle.dataset.alertToggle === "hosts" ? routeButton : hostButton;
      const otherMenu = toggle.dataset.alertToggle === "hosts" ? routeOptions : hostOptions;
      hideMenu(otherButton, otherMenu);
      menu.hidden = !menu.hidden;
      toggle.setAttribute("aria-expanded", String(!menu.hidden));
      return;
    }
    if (!event.target.closest("[data-alert-picker]")) {
      hideMenu(hostButton, hostOptions);
      hideMenu(routeButton, routeOptions);
    }
    const edit = event.target.closest("[data-alert-edit]");
    if (!edit) return;
    let rule;
    try { rule = JSON.parse(edit.dataset.alertEdit); } catch (_) { return; }
    form.reset();
    for (const key of ["id", "name", "type", "action", "method", "status", "search", "threshold", "window", "cooldown", "channel", "target"]) {
      const input = form.elements.namedItem(key);
      if (input && rule[key] !== undefined && rule[key] !== null) input.value = String(rule[key]);
    }
    const scopes = Array.isArray(rule.scopes) ? rule.scopes :
      (rule.host ? [{host: rule.host, routes: rule.route ? [rule.route] : []}] : []);
    hostChecks.forEach((item) => { item.checked = scopes.some((scope) => scope.host === item.value); });
    updatePickers();
    routeChecks.forEach((item) => {
      item.checked = !item.closest("[data-alert-route-item]").hidden &&
        scopes.some((scope) => (scope.site || hostChecks.find((host) => host.value === scope.host)?.dataset.site) === item.dataset.site &&
          Array.isArray(scope.routes) && scope.routes.includes(item.value));
    });
    updatePickers();
    form.scrollIntoView({behavior:"smooth",block:"center"});
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      hideMenu(hostButton, hostOptions);
      hideMenu(routeButton, routeOptions);
    }
  });
  form.addEventListener("submit", updatePickers);
  updatePickers();
})();

// Logs use the same inventory-backed, multi-host/route selectors as Alerts.
(() => {
  if (typeof document === "undefined" || typeof document.getElementById !== "function") return;
  const form = document.getElementById("logFilterForm");
  if (!form) return;
  const hostChecks = Array.from(form.querySelectorAll("[data-log-host]"));
  const routeChecks = Array.from(form.querySelectorAll("[data-log-route]"));
  const hostButton = document.getElementById("logHostButton");
  const routeButton = document.getElementById("logRouteButton");
  const hostOptions = document.getElementById("logHostOptions");
  const routeOptions = document.getElementById("logRouteOptions");
  const scopesField = form.querySelector('input[name="scopes_json"]');
  if (!hostButton || !routeButton || !hostOptions || !routeOptions || !scopesField) return;
  const checked = (items) => items.filter((item) => item.checked);
  const shorten = (values, fallback) => values.length === 0 ? fallback :
    (values.length <= 2 ? values.join(", ") : `${values.length} selected`);
  const hideMenu = (button, menu) => {
    menu.hidden = true;
    button.setAttribute("aria-expanded", "false");
  };
  function updatePickers() {
    const selectedHosts = checked(hostChecks);
    const selectedSites = new Set(selectedHosts.map((item) => item.dataset.site));
    routeChecks.forEach((item) => {
      const available = selectedSites.has(item.dataset.site);
      item.closest("[data-log-route-item]").hidden = !available;
      if (!available) item.checked = false;
    });
    hostButton.textContent = shorten(selectedHosts.map((item) => item.value), "All hosts (select to filter)");
    routeButton.disabled = selectedHosts.length === 0 || !routeChecks.some((item) => !item.closest("[data-log-route-item]").hidden);
    const selectedRoutes = checked(routeChecks);
    routeButton.textContent = routeButton.disabled ?
      (selectedHosts.length ? "No routes configured for these hosts" : "Select hosts first") :
      shorten(selectedRoutes.map((item) => `${item.dataset.site} · ${item.value}`), "All routes (select to filter)");
    if (routeButton.disabled) hideMenu(routeButton, routeOptions);
    scopesField.value = JSON.stringify(selectedHosts.map((item) => ({
      host: item.value,
      site: item.dataset.site,
      routes: selectedRoutes.filter((route) => route.dataset.site === item.dataset.site).map((route) => route.value)
    })));
  }
  hostChecks.forEach((item) => item.addEventListener("change", updatePickers));
  routeChecks.forEach((item) => item.addEventListener("change", updatePickers));
  document.addEventListener("click", (event) => {
    const toggle = event.target.closest("[data-log-toggle]");
    if (toggle && !toggle.disabled) {
      const menu = toggle.dataset.logToggle === "hosts" ? hostOptions : routeOptions;
      const otherButton = toggle.dataset.logToggle === "hosts" ? routeButton : hostButton;
      const otherMenu = toggle.dataset.logToggle === "hosts" ? routeOptions : hostOptions;
      hideMenu(otherButton, otherMenu);
      menu.hidden = !menu.hidden;
      toggle.setAttribute("aria-expanded", String(!menu.hidden));
      return;
    }
    if (!event.target.closest("[data-log-picker]")) {
      hideMenu(hostButton, hostOptions);
      hideMenu(routeButton, routeOptions);
    }
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      hideMenu(hostButton, hostOptions);
      hideMenu(routeButton, routeOptions);
    }
  });
  // Preserve both host and route selections on navigation/reload/export.
  let savedScopes = [];
  try {
    const parsed = JSON.parse(form.dataset.logInitialScopes || scopesField.value || "[]");
    if (Array.isArray(parsed)) savedScopes = parsed;
  } catch (_) { savedScopes = []; }
  hostChecks.forEach((item) => {
    item.checked = savedScopes.some((scope) => scope.host === item.value && scope.site === item.dataset.site);
  });
  updatePickers();
  routeChecks.forEach((item) => {
    item.checked = !item.closest("[data-log-route-item]").hidden && savedScopes.some((scope) =>
      scope.site === item.dataset.site && Array.isArray(scope.routes) && scope.routes.includes(item.value));
  });
  updatePickers();
  const submitButton = document.getElementById("logSearchButton");
  const spinner = document.getElementById("logSearchSpinner");
  const buttonLabel = document.getElementById("logSearchButtonLabel");
  const feedback = document.getElementById("logSearchFeedback");
  function hasSearchFilter() {
    return checked(hostChecks).length > 0 ||
      Array.from(form.querySelectorAll('input[name], select[name]')).some((control) => {
        const value = String(control.value || "").trim();
        if (["apply", "scopes_json", "limit"].includes(control.name)) return false;
        if (control.name === "type") return value !== "" && value !== "all";
        if (control.name === "since") return Number(value) > 0;
        return value !== "";
      });
  }
  form.addEventListener("submit", (event) => {
    updatePickers();
    if (!hasSearchFilter()) {
      event.preventDefault();
      if (feedback) {
        feedback.hidden = false;
        feedback.className = "small mt-3 text-danger";
        feedback.textContent = "Choose at least one filter before searching.";
      }
      return;
    }
    form.setAttribute("aria-busy", "true");
    if (submitButton) submitButton.disabled = true;
    if (spinner) { spinner.hidden = false; spinner.classList.remove("d-none"); }
    if (buttonLabel) buttonLabel.textContent = "Searching…";
    if (feedback) {
      feedback.hidden = false;
      feedback.className = "small mt-3 text-primary";
      feedback.textContent = "Searching logs. Please wait…";
    }
  });
  // Browsers can restore a previous page from BFCache; never leave the button
  // in an in-progress state after navigating back to the filter form.
  if (typeof window !== "undefined" && typeof window.addEventListener === "function") {
    window.addEventListener("pageshow", () => {
      form.removeAttribute("aria-busy");
      if (submitButton) submitButton.disabled = false;
      if (spinner) { spinner.hidden = true; spinner.classList.add("d-none"); }
      if (buttonLabel) buttonLabel.textContent = "Search logs";
      if (feedback && !feedback.classList.contains("text-danger")) feedback.hidden = true;
    });
  }
})();
