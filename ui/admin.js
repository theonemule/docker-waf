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
      const method = (form.method || "POST").toUpperCase();
      const action = new URL(form.getAttribute("action") || location.href, location.href);
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
      return;
    }

    const form = event.target.closest("form");
    if (form && form.method.toUpperCase() === "POST" && !form.matches("[data-native-submit]") && !form.querySelector('input[type="file"]')) {
      event.preventDefault();
      await submitAction(form, event);
    }
  });
})();