// 右側の ESC を SAVE1、SPC を LOAD1 に置き換える（ステート1のセーブ・ロード）
(function () {
    var SLOTS = {
        ESC: { label: 'SAVE1', ctl: 'SAVE_STATE_1' },
        SPC: { label: 'LOAD1', ctl: 'LOAD_STATE_1' }
    };
    var lastTouch = 0;

    function relabel() {
        var right = document.getElementById('wmsx-touch-right');
        if (!right) return;
        var btns = right.querySelectorAll('.wmsx-touch-button');
        for (var i = 0; i < btns.length; i++) {
            var b = btns[i];
            var slot = b.getAttribute('data-msx-slot');
            if (!slot) {
                var t = (b.textContent || '').trim();
                if (SLOTS[t]) {
                    slot = t;
                    b.setAttribute('data-msx-slot', slot);
                    b.classList.add('msx-slot');
                }
            }
            if (slot && b.textContent !== SLOTS[slot].label) b.textContent = SLOTS[slot].label;
        }
    }
    setInterval(relabel, 400);

    function press(slot) {
        try {
            var mc = WMSX.room.machineControls;
            var code = wmsx.MachineControls[SLOTS[slot].ctl];
            mc.processControlState(code, true);
            setTimeout(function () { mc.processControlState(code, false); }, 80);
            if (navigator.vibrate) navigator.vibrate(30);
        } catch (err) {}
    }

    function handle(e) {
        var el = e.target && e.target.closest ? e.target.closest('[data-msx-slot]') : null;
        if (!el) return;
        e.stopImmediatePropagation();
        if (e.cancelable) e.preventDefault();
        if (e.type === 'touchstart') {
            lastTouch = Date.now();
            press(el.getAttribute('data-msx-slot'));
        } else if (e.type === 'mousedown') {
            if (Date.now() - lastTouch > 800) press(el.getAttribute('data-msx-slot'));
        }
    }

    ['touchstart', 'touchend', 'mousedown', 'mouseup'].forEach(function (n) {
        document.addEventListener(n, handle, { capture: true, passive: false });
    });
})();
