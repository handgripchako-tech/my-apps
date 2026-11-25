package com.chako.timer

import android.app.Application
import android.content.Intent
import android.os.Build
import android.util.Log
import kotlin.system.exitProcess

/**
 * 落ちたとき、別プロセスの CrashActivity にエラー内容を表示する（原因調べ用）。
 * アプリが起動直後に落ちても、この画面は出る。
 */
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        val prev = Thread.getDefaultUncaughtExceptionHandler()
        val inCrashProc = Build.VERSION.SDK_INT >= 28 && (getProcessName() ?: "").endsWith(":crash")
        Thread.setDefaultUncaughtExceptionHandler { t, e ->
            if (inCrashProc) {
                prev?.uncaughtException(t, e)
            } else {
                val trace = Log.getStackTraceString(e)
                try {
                    getSharedPreferences("timer", MODE_PRIVATE).edit()
                        .putString("crash", trace).commit()
                } catch (_: Exception) {
                }
                try {
                    val i = Intent(this, CrashActivity::class.java)
                    i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                    i.putExtra("trace", "[${t.name}]\n" + trace.take(6000))
                    startActivity(i)
                    Thread.sleep(400)
                } catch (_: Exception) {
                }
                android.os.Process.killProcess(android.os.Process.myPid())
                exitProcess(10)
            }
        }
    }
}
