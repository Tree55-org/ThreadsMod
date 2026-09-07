package threadsmod.inlinecontrol;

import android.content.Context;
import android.content.res.Configuration;
import android.os.LocaleList;

import java.util.Locale;

/** Resource-free English/Vietnamese copy for the combined Block-and-report modal. */
final class InlineBlockStrings {
    final String title;
    final String unknownAccount;
    final String postExcerpt;
    final String reportReason;
    final String alsoBlockLabel;
    final String disclosure;
    final String cancel;
    final String block;
    final String report;

    private final boolean vietnamese;

    private InlineBlockStrings(boolean vietnamese) {
        this.vietnamese = vietnamese;
        if (vietnamese) {
            title = "Chặn và báo cáo";
            unknownAccount = "Tài khoản Threads";
            postExcerpt = "Trích đoạn bài viết";
            reportReason = "Lý do báo cáo";
            alsoBlockLabel = "Đồng thời chặn trang cá nhân này";
            disclosure = "Báo cáo được xếp hàng đợi để gửi nền. Máy chủ có thể nhận bí danh ổn định, ngôn ngữ/múi giờ, IP, User-Agent và vị trí gần đúng; hủy có thể thất bại khi đang gửi và báo cáo đã chấp nhận không thể thu hồi.";
            cancel = "Hủy";
            block = "Chặn";
            report = "Báo cáo";
        } else {
            title = "Block and report";
            unknownAccount = "Threads account";
            postExcerpt = "Post excerpt";
            reportReason = "Report reason";
            alsoBlockLabel = "Also block this profile";
            disclosure = "This queues a report for background delivery. The server operator may receive your stable pseudonym, language/time zone, IP address, User-Agent, and approximate location; cancellation can fail once delivery is active, and an accepted report cannot be recalled.";
            cancel = "Cancel";
            block = "Block";
            report = "Report";
        }
    }

    static InlineBlockStrings forContext(Context context) {
        Locale locale = null;
        if (context != null) {
            try {
                Configuration configuration = context.getResources().getConfiguration();
                LocaleList locales = configuration.getLocales();
                if (locales != null && !locales.isEmpty()) {
                    locale = locales.get(0);
                }
            } catch (Throwable ignored) {
                // A locale lookup failure falls back to the process locale below.
            }
        }
        if (locale == null) {
            locale = Locale.getDefault();
        }
        return new InlineBlockStrings(
                locale != null && "vi".equalsIgnoreCase(locale.getLanguage()));
    }

    String accountMetadata(String authorId) {
        return "ID " + authorId + "  ·  Threads";
    }
}
