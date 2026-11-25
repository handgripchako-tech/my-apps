// 早送りボタンをトグル式にする（1回押すとオン、もう1回押すとオフ）
(function () {
    var on = false;
    var bypass = false;
    var lastTouch = 0;

    function inFast(t) {
        return t && t.closest && t.closest('#wmsx-touch-fast');
    }

    function fire(type) {
        var el = document.getElementById('wmsx-touch-fast');
        if (!el) return;
        bypass = true;
        try {
            el.dispatchEvent(new Event(type, { bubbles: true, cancelable: true }));
        } finally {
            bypass = false;
        }
    }

    function toggle() {
        on = !on;
        var el = document.getElementById('wmsx-touch-fast');
        if (el) el.classList.toggle('ff-on', on);
        fire(on ? 'touchstart' : 'touchend');
    }

    function handle(e) {
        if (bypass || !inFast(e.target)) return;
        e.stopImmediatePropagation();
        if (e.cancelable) e.preventDefault();
        if (e.type === 'touchstart') {
            lastTouch = Date.now();
            toggle();
        } else if (e.type === 'mousedown') {
            if (Date.now() - lastTouch > 800) toggle();
        }
    }

    ['touchstart', 'touchend', 'mousedown', 'mouseup'].forEach(function (n) {
        document.addEventListener(n, handle, { capture: true, passive: false });
    });
})();
