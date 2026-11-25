package com.chako.timer

import android.app.AlarmManager
import android.app.PendingIntent
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

data class Job(
    val id: Int,
    var hour: Int,
    var minute: Int,
    var pkg: String,
    var label: String,
    var enabled: Boolean,
    var skipIfRunning: Boolean,
    var macro: String,
    var stopMin: Int = 0,
    var stopAt: Int = -1,      // 毎日の終了時刻（0時からの分）。-1=なし
    var noLaunch: Boolean = false, // true=起動はせず、終了だけ行う
    var once: Boolean = false,     // true=1回だけ（終わったら自動でOFF）
    var onceStarted: Boolean = false // 1回だけの予定で、起動がもう済んだか
)

object Store {
    private fun p(c: Context) = c.getSharedPreferences("timer", Context.MODE_PRIVATE)

    fun load(c: Context): MutableList<Job> {
        val out = mutableListOf<Job>()
        val arr = JSONArray(p(c).getString("jobs", "[]"))
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            out.add(
                Job(
                    o.getInt("id"), o.getInt("hour"), o.getInt("minute"),
                    o.getString("pkg"), o.getString("label"),
                    o.getBoolean("enabled"), o.getBoolean("skip"), o.getString("macro"),
                    o.optInt("stop", 0), o.optInt("stopAt", -1), o.optBoolean("noLaunch", false),
                    o.optBoolean("once", false), o.optBoolean("onceStarted", false)
                )
            )
        }
        return out
    }

    fun save(c: Context, list: List<Job>) {
        val arr = JSONArray()
        for (j in list) {
            arr.put(
                JSONObject()
                    .put("id", j.id).put("hour", j.hour).put("minute", j.minute)
                    .put("pkg", j.pkg).put("label", j.label)
                    .put("enabled", j.enabled).put("skip", j.skipIfRunning).put("macro", j.macro).put("stop", j.stopMin)
                    .put("stopAt", j.stopAt).put("noLaunch", j.noLaunch)
                    .put("once", j.once).put("onceStarted", j.onceStarted)
            )
        }
        p(c).edit().putString("jobs", arr.toString()).apply()
    }

    fun get(c: Context, id: Int): Job? = load(c).firstOrNull { it.id == id }

    fun put(c: Context, job: Job) {
        val list = load(c)
        val i = list.indexOfFirst { it.id == job.id }
        if (i >= 0) list[i] = job
        save(c, list)
    }

    fun log(c: Context, msg: String) {
        val t = SimpleDateFormat("MM/dd HH:mm:ss", Locale.JAPAN).format(Date())
        val old = (p(c).getString("log", "") ?: "").lines().filter { it.isNotBlank() }.takeLast(19)
        p(c).edit().putString("log", (old + "$t $msg").joinToString("\n")).apply()
    }

    fun readLog(c: Context): String = p(c).getString("log", "") ?: ""
}

object Scheduler {
    private fun pending(c: Context, id: Int): PendingIntent =
        PendingIntent.getBroadcast(
            c, id, Intent(c, AlarmReceiver::class.java).putExtra("id", id),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

    fun nextTime(j: Job): Long {
        val cal = Calendar.getInstance()
        cal.set(Calendar.HOUR_OF_DAY, j.hour)
        cal.set(Calendar.MINUTE, j.minute)
        cal.set(Calendar.SECOND, 0)
        cal.set(Calendar.MILLISECOND, 0)
        if (cal.timeInMillis <= System.currentTimeMillis() + 1000) cal.add(Calendar.DAY_OF_YEAR, 1)
        return cal.timeInMillis
    }

    /** 次回（今日 or 明日）の1回分を予約する。発火したら次の日をまた予約する。 */
    fun schedule(c: Context, j: Job) {
        val am = c.getSystemService(AlarmManager::class.java)
        val pi = pending(c, j.id)
        if (!j.enabled) {
            am.cancel(pi)
            cancelStopAt(c, j)
            return
        }
        if (j.noLaunch || (j.once && j.onceStarted)) {
            am.cancel(pi)
        } else {
            val show = PendingIntent.getActivity(
                c, 0, Intent(c, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE
            )
            try {
                am.setAlarmClock(AlarmManager.AlarmClockInfo(nextTime(j), show), pi)
            } catch (e: SecurityException) {
                // 権限が無くてもアプリが落ちないようにする
                Store.log(c, "アラーム予約に失敗（権限）: " + (e.message ?: "").take(80))
            }
        }
        scheduleStopAt(c, j)
    }

    private fun stopAtPending(c: Context, j: Job): PendingIntent =
        PendingIntent.getBroadcast(
            c, -j.id - 1_000_000_000,
            Intent(c, StopReceiver::class.java).putExtra("id", j.id).putExtra("daily", true),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

    /** 毎日の終了時刻（起動のしかたに関係なく動く）を予約する。 */
    fun scheduleStopAt(c: Context, j: Job) {
        val am = c.getSystemService(AlarmManager::class.java)
        if (!j.enabled || j.stopAt < 0) {
            am.cancel(stopAtPending(c, j))
            return
        }
        // 1回だけ（まだ起動前）の予定は、起動より後の最初の終了時刻にする
        val baseMs = if (j.once && !j.noLaunch && !j.onceStarted) nextTime(j)
        else System.currentTimeMillis() + 1000
        val cal = Calendar.getInstance()
        cal.timeInMillis = baseMs
        cal.set(Calendar.HOUR_OF_DAY, j.stopAt / 60)
        cal.set(Calendar.MINUTE, j.stopAt % 60)
        cal.set(Calendar.SECOND, 0)
        cal.set(Calendar.MILLISECOND, 0)
        if (cal.timeInMillis <= baseMs) cal.add(Calendar.DAY_OF_YEAR, 1)
        try {
            am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, cal.timeInMillis, stopAtPending(c, j))
        } catch (e: SecurityException) {
            Store.log(c, "終了時刻の予約に失敗（権限）")
        }
    }

    fun cancelStopAt(c: Context, j: Job) {
        c.getSystemService(AlarmManager::class.java).cancel(stopAtPending(c, j))
    }

    fun cancel(c: Context, j: Job) {
        c.getSystemService(AlarmManager::class.java).cancel(pending(c, j.id))
        cancelStop(c, j)
        cancelStopAt(c, j)
    }

    private fun stopPending(c: Context, j: Job): PendingIntent =
        PendingIntent.getBroadcast(
            c, -j.id, Intent(c, StopReceiver::class.java).putExtra("id", j.id),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

    /** 起動した時点から stopMin 分後に「終了」を予約する。 */
    fun scheduleStop(c: Context, j: Job) {
        if (j.stopMin <= 0) return
        val am = c.getSystemService(AlarmManager::class.java)
        val at = System.currentTimeMillis() + j.stopMin * 60_000L
        try {
            am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, stopPending(c, j))
        } catch (e: SecurityException) {
            Store.log(c, "終了の予約に失敗（権限）")
        }
    }

    fun cancelStop(c: Context, j: Job) {
        c.getSystemService(AlarmManager::class.java).cancel(stopPending(c, j))
    }

    fun scheduleAll(c: Context) {
        for (j in Store.load(c)) schedule(c, j)
    }
}

object Usage {
    /** 直近のイベントを追って、いま前面にいるアプリが pkg かどうかを返す。 */
    @Suppress("DEPRECATION")
    fun isForeground(c: Context, pkg: String): Boolean {
        val um = c.getSystemService(UsageStatsManager::class.java)
        val now = System.currentTimeMillis()
        val ev = um.queryEvents(now - 6 * 3600 * 1000L, now) ?: return false
        val e = UsageEvents.Event()
        var cur: String? = null
        while (ev.hasNextEvent()) {
            ev.getNextEvent(e)
            when (e.eventType) {
                UsageEvents.Event.MOVE_TO_FOREGROUND -> cur = e.packageName
                UsageEvents.Event.MOVE_TO_BACKGROUND, 23 -> if (cur == e.packageName) cur = null
            }
        }
        return cur == pkg
    }
}

data class Step(val cmd: String, val args: List<String>) {
    fun n(i: Int): Float = args.getOrNull(i)?.toFloatOrNull() ?: 0f
}

object Macro {
    /** 1行1手順。例: 待つ 5 / タップ 540 1200 / スワイプ x1 y1 x2 y2 [ミリ秒] / 戻る / 文字 開始 */
    fun parse(text: String): List<Step> = text.lines().mapNotNull { raw ->
        val l = raw.trim()
        if (l.isEmpty() || l.startsWith("#")) return@mapNotNull null
        val t = l.split(Regex("[\\s　,]+"))
        val cmd = when (t[0]) {
            "待つ", "待機", "wait" -> "wait"
            "タップ", "tap" -> "tap"
            "長押し", "long" -> "long"
            "スワイプ", "swipe" -> "swipe"
            "戻る", "back" -> "back"
            "文字", "文字タップ", "テキスト", "text" -> "text"
            else -> return@mapNotNull null
        }
        Step(cmd, t.drop(1))
    }
}

/**
 * PINを端末内のKeystoreで暗号化して保存する。通信はしない・ログにも出さない。
 * 連続2回ロックが解けなかったら、ロックアウト防止のため自動入力を止める。
 */
object PinStore {
    private const val ALIAS = "timer_pin_key"
    private fun p(c: Context) = c.getSharedPreferences("timer_pin", Context.MODE_PRIVATE)

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore")
        ks.load(null)
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        kg.init(
            KeyGenParameterSpec.Builder(
                ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
        )
        return kg.generateKey()
    }

    fun save(c: Context, pin: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val ct = cipher.doFinal(pin.toByteArray(Charsets.UTF_8))
        val packed = Base64.encodeToString(cipher.iv + ct, Base64.NO_WRAP)
        p(c).edit().putString("pin", packed).putInt("fails", 0).apply()
    }

    fun load(c: Context): String? {
        val packed = p(c).getString("pin", null) ?: return null
        return try {
            val raw = Base64.decode(packed, Base64.NO_WRAP)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, raw.copyOfRange(0, 12)))
            String(cipher.doFinal(raw.copyOfRange(12, raw.size)), Charsets.UTF_8)
        } catch (e: Exception) {
            null
        }
    }

    fun has(c: Context): Boolean = p(c).getString("pin", null) != null
    fun usable(c: Context): Boolean = has(c) && p(c).getInt("fails", 0) < 2
    fun stoppedByFails(c: Context): Boolean = has(c) && p(c).getInt("fails", 0) >= 2
    fun clear(c: Context) {
        p(c).edit().clear().apply()
    }

    fun recordResult(c: Context, ok: Boolean) {
        val f = if (ok) 0 else p(c).getInt("fails", 0) + 1
        p(c).edit().putInt("fails", f).apply()
    }
}
