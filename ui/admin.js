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


  // Persist a single completed-action notification across the server's 303 redirect.
  const flashKey = "liteedge:last-action";
  function notify(message, kind = "info", persistent = false) {
    let region = document.getElementById("liteedge-action-feedback");
    if (!region) {
      region = document.createElement("div");
      region.id = "liteedge-action-feedback";
      region.setAttribute("role", "status");
      region.setAttribute("aria-live", "polite");
      region.style.cssText = "position:fixed;right:1rem;top:4.5rem;z-index:1200;width:min(440px,calc(100vw - 2rem));";
      document.body.appendChild(region);
    }
    const alert = document.createElement("div");
    alert.className = "alert alert-" + kind + " shadow-sm d-flex align-items-start gap-2";
    alert.setAttribute("role", kind === "danger" ? "alert" : "status");
    const label = document.createElement("span");
    label.style.flex = "1";
    label.textContent = message;
    const close = document.createElement("button");
    close.type = "button";
    close.className = "btn-close";
    close.setAttribute("aria-label", "Dismiss notification");
    close.addEventListener("click", () => alert.remove());
    alert.append(label, close);
    region.replaceChildren(alert);
    if (!persistent) window.setTimeout(() => { if (alert.isConnected) alert.remove(); }, 8500);
  }

  try {
    const flash = JSON.parse(sessionStorage.getItem(flashKey) || "null");
    sessionStorage.removeItem(flashKey);
    if (flash && typeof flash.message === "string") notify(flash.message, flash.kind || "success");
  } catch (_) { /* private browsing or storage restrictions should not break forms */ }

  function actionName(form, button) {
    const explicit = form.dataset.actionLabel;
    if (explicit) return explicit;
    const label = (button && button.textContent || "").trim().replace(/\\s+/g, " ");
    return label || "Action";
  }

  function requestError(response, body) {
    const doc = new DOMParser().parseFromString(body || "", "text/html");
    const errorTitle = doc.querySelector("h1, .alert-danger h2");
    const errorDetails = doc.querySelector(".alert-danger pre, .alert-danger");
    if (errorTitle && /request failed|error|not found/i.test(errorTitle.textContent || "")) {
      return (errorDetails && errorDetails.textContent || errorTitle.textContent || "Request failed").trim();
    }
    if (!response.ok) return (errorDetails && errorDetails.textContent || body || "Request failed").trim().slice(0, 700);
    return null;
  }

  async function submitAction(form, event) {
    const submitter = event.submitter || form.querySelector('button[type="submit"], input[type="submit"]');
    if (form.dataset.submitting === "true") return;
    const label = actionName(form, submitter);
    const buttons = Array.from(form.querySelectorAll('button[type="submit"], input[type="submit"]'));
    form.dataset.submitting = "true";
    buttons.forEach(b => { b.disabled = true; b.setAttribute("aria-busy", "true"); });
    const previousText = submitter && submitter.tagName === "BUTTON" ? submitter.textContent : null;
    if (submitter && previousText != null) submitter.textContent = "Working…";
    const started = "Running " + label.toLowerCase() + "…";
    notify(started, "info", true);
    try {
      const data = new FormData(form);
      if (submitter && submitter.name) data.set(submitter.name, submitter.value);
      // Honor per-button formaction/formmethod (e.g., Save email versus Issue).
      const method = (submitter?.getAttribute?.("formmethod") || form.method || "POST").toUpperCase();
      const destination = submitter?.getAttribute?.("formaction") || form.getAttribute("action") || location.href;
      const action = new URL(destination, location.href);
      const request = { method, credentials: "same-origin", headers: { "Accept": "text/html" } };
      if (method === "GET") {
        for (const [key, value] of data) action.searchParams.append(key, value);
      } else {
        request.body = new URLSearchParams(data);
      }
      const response = await fetch(action.toString(), request);
      const body = await response.text();
      const error = requestError(response, body);
      if (error) throw new Error(error);
      if (response.redirected) {
        try { sessionStorage.setItem(flashKey, JSON.stringify({message:label + " completed successfully.",kind:"success"})); } catch (_) {}
        notify(label + " completed. Refreshing…", "success", true);
        window.location.assign(response.url);
      } else {
        notify(label + " completed successfully.", "success");
      }
    } catch (error) {
      notify(label + " failed: " + (error.message || String(error)), "danger", true);
    } finally {
      delete form.dataset.submitting;
      buttons.forEach(b => { b.disabled = false; b.removeAttribute("aria-busy"); });
      if (submitter && previousText != null) submitter.textContent = previousText;
    }
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
    if (button) { button.disabled = true; button.setAttribute("aria-busy", "true"); }
    showStatus(form, "Importing and validating…", false);
    notify("Importing and validating bundle…", "info", true);
    try {
      const response = await fetch(endpoint, {
        method: "POST",
        headers: {"Content-Type": "application/octet-stream"},
        body: file
      });
      const text = await response.text();
      if (!response.ok) throw new Error(text || "Import failed.");
      showStatus(form, text || "Import complete.", false);
      try { sessionStorage.setItem(flashKey, JSON.stringify({ message: "Import completed successfully.", kind: "success" })); } catch (_) {}
      notify("Import completed. Refreshing…", "success", true);
      window.location.assign(form.dataset.redirect || "/");
    } catch (error) {
      showStatus(form, error.message || String(error), true);
      notify("Import failed: " + (error.message || String(error)), "danger", true);
    } finally {
      if (button) { button.disabled = false; button.removeAttribute("aria-busy"); }
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
      return;
    }

    const crsForm = event.target.closest(".crs-import-form");
    if (crsForm) {
      event.preventDefault();
      await uploadRaw(crsForm, "/admin/owasp/crs/import");
      return;
    }

    const form = event.target.closest("form");
    if (form && form.method.toUpperCase() === "POST" && !form.matches("[data-native-submit]") && !form.querySelector('input[type="file"]')) {
      event.preventDefault();
      await submitAction(form, event);
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
