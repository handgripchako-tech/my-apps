package com.chako.np2

import android.view.Surface

/** NP2kai コアを動かす C++ 側の「枠」への窓口 */
object Native {
    init {
        System.loadLibrary("np2front")
    }

    @JvmStatic external fun nInit(core: String, sys: String, save: String): Boolean
    @JvmStatic external fun nLoad(path: String): Boolean
    @JvmStatic external fun nStart()
    @JvmStatic external fun nPause(p: Boolean)
    @JvmStatic external fun nFastForward(level: Int)
    @JvmStatic external fun nSetTurbo(disk: Boolean, light: Boolean): Boolean
    @JvmStatic external fun nSetFdd(drive: Int, path: String): Boolean
    @JvmStatic external fun nReset()
    @JvmStatic external fun nSaveState(path: String): Boolean
    @JvmStatic external fun nLoadState(path: String): Boolean
    @JvmStatic external fun nStop()
    @JvmStatic external fun nSetSurface(s: Surface?)
    @JvmStatic external fun nKey(code: Int, down: Boolean)
    @JvmStatic external fun nJoy(id: Int, down: Boolean)
    @JvmStatic external fun nMouseMove(dx: Int, dy: Int)
    @JvmStatic external fun nMouseBtn(btn: Int, down: Boolean)
}
