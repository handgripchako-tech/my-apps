package com.chako.remote

import java.net.HttpURLConnection
import java.net.URL

object Net {
    /** 相手のスマホに GET する。失敗したら null。必ず別スレッドで呼ぶこと。 */
    fun get(host: String, path: String, timeoutMs: Int = 5000): ByteArray? {
        return try {
            val c = URL("http://$host:${RemoteService.PORT}$path").openConnection() as HttpURLConnection
            c.connectTimeout = timeoutMs
            c.readTimeout = timeoutMs
            try {
                if (c.responseCode != 200) null else c.inputStream.readBytes()
            } finally {
                c.disconnect()
            }
        } catch (e: Exception) {
            null
        }
    }
}
