package com.chako.launcher;

import java.time.DayOfWeek;
import java.time.LocalDate;

/** 日本の祝日（1980年〜）。通信なしで計算する。振替休日・国民の休日・春分/秋分・臨時の移動に対応 */
final class Holidays {
    private Holidays() {}

    /** 第n月曜日の日付 */
    private static int nthMon(int y, int m, int n) {
        int first = LocalDate.of(y, m, 1).getDayOfWeek().getValue(); // 月=1
        int firstMon = 1 + (8 - first) % 7;
        return firstMon + 7 * (n - 1);
    }

    private static int shunbun(int y) {
        return (int) Math.floor(20.8431 + 0.242194 * (y - 1980) - Math.floor((y - 1980) / 4.0));
    }

    private static int shuubun(int y) {
        return (int) Math.floor(23.2488 + 0.242194 * (y - 1980) - Math.floor((y - 1980) / 4.0));
    }

    /** 振替・国民の休日を含まない、元からある祝日の名前。なければ null */
    private static String base(int y, int m, int d) {
        switch (m) {
            case 1:
                if (d == 1) return "元日";
                if (y <= 1999 ? d == 15 : d == nthMon(y, 1, 2)) return "成人の日";
                return null;
            case 2:
                if (d == 11) return "建国記念の日";
                if (y >= 2020 && d == 23) return "天皇誕生日";
                if (y == 1989 && d == 24) return "昭和天皇の大喪の礼";
                return null;
            case 3:
                if (d == shunbun(y)) return "春分の日";
                return null;
            case 4:
                if (d == 29) return y >= 2007 ? "昭和の日" : (y >= 1989 ? "みどりの日" : "天皇誕生日");
                if (y == 1959 && d == 10) return "結婚の儀";
                return null;
            case 5:
                if (d == 3) return "憲法記念日";
                if (d == 4 && y >= 2007) return "みどりの日";
                if (d == 5) return "こどもの日";
                if (y == 2019 && d == 1) return "即位の日";
                return null;
            case 6:
                if (y == 1993 && d == 9) return "結婚の儀";
                return null;
            case 7:
                if (y == 2020) return d == 23 ? "海の日" : (d == 24 ? "スポーツの日" : null);
                if (y == 2021) return d == 22 ? "海の日" : (d == 23 ? "スポーツの日" : null);
                if (y >= 2003 ? d == nthMon(y, 7, 3) : (y >= 1996 && d == 20)) return "海の日";
                return null;
            case 8:
                if (y == 2020) return d == 10 ? "山の日" : null;
                if (y == 2021) return d == 8 ? "山の日" : null;
                if (y >= 2016 && d == 11) return "山の日";
                return null;
            case 9:
                if (y >= 2003 ? d == nthMon(y, 9, 3) : d == 15) return "敬老の日";
                if (d == shuubun(y)) return "秋分の日";
                return null;
            case 10:
                if (y == 2020 || y == 2021) return null; // 7月に移動
                if (y == 2019 && d == 22) return "即位礼正殿の儀";
                if (y <= 1999 ? d == 10 : d == nthMon(y, 10, 2)) return y >= 2020 ? "スポーツの日" : "体育の日";
                return null;
            case 11:
                if (d == 3) return "文化の日";
                if (d == 23) return "勤労感謝の日";
                if (y == 1990 && d == 12) return "即位礼正殿の儀";
                return null;
            case 12:
                if (d == 23 && y >= 1989 && y <= 2018) return "天皇誕生日";
                return null;
        }
        return null;
    }

    private static String raw(LocalDate dt) {
        if (dt.getYear() < 1980) return null;
        return base(dt.getYear(), dt.getMonthValue(), dt.getDayOfMonth());
    }

    /** その日の祝日名（振替休日・国民の休日を含む）。祝日でなければ null */
    static String name(int y, int m, int d) {
        if (y < 1980 || y > 2099) return null;
        LocalDate dt = LocalDate.of(y, m, d);
        String r = raw(dt);
        if (r != null) return r;
        // 振替休日：日曜の祝日の次の（祝日でない）日。2006年までは月曜のみ
        if (y >= 1973) {
            LocalDate p = dt.minusDays(1);
            if (y >= 2007) {
                // 直前までさかのぼって、日曜の祝日にたどり着けば振替
                while (raw(p) != null && p.getDayOfWeek() != DayOfWeek.SUNDAY) p = p.minusDays(1);
                if (p.getDayOfWeek() == DayOfWeek.SUNDAY && raw(p) != null) return "振替休日";
            } else if (dt.getDayOfWeek() == DayOfWeek.MONDAY && raw(p) != null) {
                return "振替休日";
            }
        }
        // 国民の休日：前日と翌日が祝日で、日曜でも祝日でもない日
        if (y >= 1988 && dt.getDayOfWeek() != DayOfWeek.SUNDAY
                && raw(dt.minusDays(1)) != null && raw(dt.plusDays(1)) != null) {
            return "国民の休日";
        }
        return null;
    }
}
