// Injected into the SongSelect page inside StageCharts. SongSelect builds the chord sheet in the
// page (a blob: URL) and clicks a hidden <a download> link; app web views ignore that, so we
// catch it here and hand the file to the app.
(function () {
  if (window.__stagechartsDownloadHook) return;
  window.__stagechartsDownloadHook = true;
  var blobs = {};
  var createURL = URL.createObjectURL;
  URL.createObjectURL = function (obj) {
    var url = createURL.apply(this, arguments);
    try { if (obj instanceof Blob) blobs[url] = obj; } catch (e) {}
    return url;
  };
  function post(name, dataURL) {
    window.webkit.messageHandlers.stagechartsDownload.postMessage({ name: name || "download", data: dataURL });
  }
  function send(href, name) {
    var read = function (blob) {
      var fr = new FileReader();
      fr.onload = function () { post(name, fr.result); };
      fr.readAsDataURL(blob);
    };
    if (blobs[href]) read(blobs[href]);
    else fetch(href).then(function (r) { return r.blob(); }).then(read);
  }
  function intercept(a) {
    var href = String(a.href || "");
    if (a.hasAttribute && a.hasAttribute("download") && /^(blob:|data:)/.test(href)) {
      send(href, a.getAttribute("download"));
      return true;
    }
    return false;
  }
  var dispatch = HTMLAnchorElement.prototype.dispatchEvent;
  HTMLAnchorElement.prototype.dispatchEvent = function (e) {
    if (e && e.type === "click" && intercept(this)) return true;
    return dispatch.apply(this, arguments);
  };
  var click = HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click = function () {
    if (intercept(this)) return;
    return click.apply(this, arguments);
  };
  document.addEventListener("click", function (e) {
    var a = e.target && e.target.closest && e.target.closest("a[download]");
    if (a && intercept(a)) { e.preventDefault(); e.stopPropagation(); }
  }, true);
})();
