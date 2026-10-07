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