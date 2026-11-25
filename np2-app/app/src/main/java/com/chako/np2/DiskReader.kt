package com.chako.np2

import java.io.File
import java.io.RandomAccessFile
import java.nio.charset.Charset

/** ディスクイメージ(HDI/FDI/生イメージ)の FAT12/16 を読むだけの軽量リーダー。D88 は非対応。 */
class DiskReader private constructor(
    private val raf: RandomAccessFile,
    private val base: Long,
    private val length: Long,
    val sectorSize: Int,
    val sectors: Int,
    val heads: Int,
    val isHdd: Boolean
) {
    class Entry(val name: String, val isDir: Boolean, val cluster: Int, val size: Long)

    class Volume(val name: String, val fat: Fat)

    companion object {
        private val SJIS: Charset = Charset.forName("windows-31j")
        private val SEC_SIZES = intArrayOf(256, 512, 1024, 2048, 4096)

        fun u16(b: ByteArray, o: Int) = (b[o].toInt() and 0xFF) or ((b[o + 1].toInt() and 0xFF) shl 8)
        fun u32(b: ByteArray, o: Int): Long = (u16(b, o).toLong()) or (u16(b, o + 2).toLong() shl 16)

        /** 開けない形式なら null */
        fun open(path: String): DiskReader? {
            return try {
                val f = File(path)
                val ext = f.name.substringAfterLast('.', "").lowercase()
                if (ext in listOf("d88", "88d", "d98", "98d", "d68")) return null
                val raf = RandomAccessFile(f, "r")
                val len = raf.length()
                if (ext == "hdi" || ext == "fdi") {
                    val h = ByteArray(32)
                    raf.seek(0); raf.readFully(h)
                    val headSize = u32(h, 8)
                    val ss = u32(h, 16).toInt()
                    val sec = u32(h, 20).toInt()
                    val hd = u32(h, 24).toInt()
                    if (ss !in SEC_SIZES || sec < 1 || hd < 1 || headSize < 28 || headSize > len) {
                        raf.close(); return null
                    }
                    DiskReader(raf, headSize, len - headSize, ss, sec, hd, ext == "hdi")
                } else {
                    var ss = 512
                    when (len) {
                        1261568L -> ss = 1024
                    }
                    DiskReader(raf, 0, len, ss, 0, 0, false)
                }
            } catch (e: Exception) {
                null
            }
        }
    }

    fun close() = try { raf.close() } catch (_: Exception) {}

    fun read(off: Long, len: Int): ByteArray {
        val out = ByteArray(len)
        if (off < 0 || off >= length || len <= 0) return out
        val n = minOf(len.toLong(), length - off).toInt()
        synchronized(raf) {
            raf.seek(base + off)
            raf.readFully(out, 0, n)
        }
        return out
    }

    fun volumes(): List<Volume> {
        val out = ArrayList<Volume>()
        val ss = sectorSize
        if (isHdd && sectors > 0) {
            val t = read(ss.toLong(), ss)
            for (i in 0 until minOf(16, ss / 32)) {
                val e = t.copyOfRange(i * 32, i * 32 + 32)
                if (e[1].toInt() == 0) continue
                val sec = e[8].toInt() and 0xFF
                val head = e[9].toInt() and 0xFF
                val cyl = u16(e, 10)
                val lba = (cyl.toLong() * heads + head) * sectors + sec
                val fat = Fat.parse(this, lba * ss) ?: continue
                var name = String(e, 16, 16, SJIS).trimEnd('\u0000', ' ')
                if (name.isEmpty()) name = "パーティション${out.size + 1}"
                out.add(Volume(name, fat))
            }
            if (out.isEmpty()) {
                for (off in longArrayOf(0, heads.toLong() * sectors * ss)) {
                    Fat.parse(this, off)?.let { out.add(Volume("ボリューム", it)) }
                }
            }
            return out
        }
        Fat.parse(this, 0)?.let { out.add(Volume("ボリューム", it)) }
        return out
    }

    class Fat private constructor(
        private val d: DiskReader, private val bps: Int, private val spc: Int,
        private val rootEntries: Int, private val clusters: Int, private val bits: Int,
        private val rootOffset: Long, private val dataOffset: Long, private val fat: ByteArray
    ) {
        companion object {
            fun parse(d: DiskReader, start: Long): Fat? {
                if (start < 0 || start + 512 > d.length) return null
                val b = d.read(start, 512)
                val bps = u16(b, 0x0B)
                val spc = b[0x0D].toInt() and 0xFF
                val res = u16(b, 0x0E)
                val nf = b[0x10].toInt() and 0xFF
                val rootEnt = u16(b, 0x11)
                val t16 = u16(b, 0x13)
                val media = b[0x15].toInt() and 0xFF
                val spf = u16(b, 0x16)
                val t32 = u32(b, 0x20)
                if (bps !in SEC_SIZES) return null
                if (spc < 1 || spc > 128 || (spc and (spc - 1)) != 0) return null
                if (res < 1 || nf < 1 || nf > 2 || rootEnt < 1 || spf < 1) return null
                if ((media and 0xF0) != 0xF0) return null
                val total = if (t16 != 0) t16.toLong() else t32
                if (total < 1) return null
                val rootSectors = (rootEnt * 32 + bps - 1) / bps
                val dataSectors = total - res - nf.toLong() * spf - rootSectors
                if (dataSectors < 1) return null
                val clusters = (dataSectors / spc).toInt()
                val bits = when {
                    clusters < 4085 -> 12
                    clusters < 65525 -> 16
                    else -> return null
                }
                val rootOffset = start + (res + nf.toLong() * spf) * bps
                if (rootOffset > d.length) return null
                val dataOffset = rootOffset + rootSectors.toLong() * bps
                val fat = d.read(start + res.toLong() * bps, spf * bps)
                return Fat(d, bps, spc, rootEnt, clusters, bits, rootOffset, dataOffset, fat)
            }
        }

        private val clusterBytes get() = spc * bps

        private fun next(c: Int): Int {
            if (bits == 12) {
                val o = c + (c shr 1)
                if (o + 1 >= fat.size) return 0xFFF
                val w = (fat[o].toInt() and 0xFF) or ((fat[o + 1].toInt() and 0xFF) shl 8)
                return if (c and 1 == 0) w and 0xFFF else w shr 4
            }
            val o = c * 2
            if (o + 1 >= fat.size) return 0xFFFF
            return u16(fat, o)
        }

        private fun chain(start: Int): List<Int> {
            val eoc = if (bits == 12) 0xFF8 else 0xFFF8
            val out = ArrayList<Int>()
            val seen = HashSet<Int>()
            var c = start
            while (c >= 2 && c < clusters + 2 && seen.add(c)) {
                out.add(c)
                c = next(c)
                if (c >= eoc) break
            }
            return out
        }

        /** cluster == 0 でルート */
        fun list(cluster: Int): List<Entry> {
            val raw: ByteArray = if (cluster == 0) {
                d.read(rootOffset, rootEntries * 32)
            } else {
                val bo = java.io.ByteArrayOutputStream()
                for (x in chain(cluster)) bo.write(d.read(dataOffset + (x - 2).toLong() * clusterBytes, clusterBytes))
                bo.toByteArray()
            }
            val out = ArrayList<Entry>()
            var o = 0
            while (o + 32 <= raw.size) {
                val first = raw[o].toInt() and 0xFF
                if (first == 0) break
                val attr = raw[o + 11].toInt() and 0xFF
                if (first != 0xE5 && attr != 0x0F && (attr and 0x08) == 0) {
                    val nm = raw.copyOfRange(o, o + 8)
                    if ((nm[0].toInt() and 0xFF) == 0x05) nm[0] = 0xE5.toByte()
                    val base = String(nm, SJIS).trimEnd(' ', '\u0000')
                    val ext = String(raw, o + 8, 3, SJIS).trimEnd(' ', '\u0000')
                    val name = if (ext.isEmpty()) base else "$base.$ext"
                    if (name != "." && name != "..") {
                        out.add(Entry(name, (attr and 0x10) != 0, u16(raw, o + 26), u32(raw, o + 28)))
                    }
                }
                o += 32
            }
            return out
        }
    }
}
