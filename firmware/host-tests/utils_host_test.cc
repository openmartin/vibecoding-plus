#include "lan_mic_app_internal.h"

#include <cassert>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

namespace {

void ExpectLines(const std::vector<std::string>& lines,
                 std::initializer_list<const char*> expected) {
    assert(lines.size() == expected.size());
    size_t i = 0;
    for (const char* line : expected) {
        assert(lines[i] == line);
        ++i;
    }
}

void TestAsciiWrap() {
    const auto lines = WrapUtf8Lines("hello world", 5);
    ExpectLines(lines, {"hello", " worl", "d"});
}

void TestCjkWrap() {
    const auto lines = WrapUtf8Lines("你好世界", 2);
    ExpectLines(lines, {"你好", "世界"});
}

void TestNewlineFlush() {
    const auto lines = WrapUtf8Lines("a\nbc", 10);
    ExpectLines(lines, {"a", "bc"});
}

void TestMaxLines() {
    const auto lines = WrapUtf8Lines("one two three four", 4, 2);
    ExpectLines(lines, {"one ", "two "});
}

void TestFormatTodoRightTimeText() {
    // 无当前时间参考时的基本格式
    assert(FormatTodoRightTimeText("2026-07-03", nullptr) == "07/03");
    assert(FormatTodoRightTimeText("2026-07-03T08:30:00", nullptr) == "07/03 08:30");
    assert(FormatTodoRightTimeText("bad", nullptr) == "");
    assert(FormatTodoRightTimeText("", nullptr) == "");

    // 有当前时间参考时的人性化格式
    // 模拟当前时间: 2026-07-21 (周二) 12:51
    tm now = {};
    now.tm_year = 2026 - 1900;
    now.tm_mon = 6;  // 7月 (0-based)
    now.tm_mday = 21;
    now.tm_hour = 12;
    now.tm_min = 51;
    now.tm_wday = 2;  // 周二

    // 今天
    assert(FormatTodoRightTimeText("2026-07-21T14:00:00", &now) == "14:00");
    // 明天
    assert(FormatTodoRightTimeText("2026-07-22T08:00:00", &now) == "明天 08:00");
    // 本周内 (周四=4 > 周二=2)
    assert(FormatTodoRightTimeText("2026-07-23T14:00:00", &now) == "周四 14:00");
    // 今年其他日期
    assert(FormatTodoRightTimeText("2026-12-19T08:00:00", &now) == "12/19 08:00");
    // 无时间
    assert(FormatTodoRightTimeText("2026-08-01", &now) == "08/01");
    // 跨年
    assert(FormatTodoRightTimeText("2027-01-15T10:00:00", &now) == "2027/01/15");

    // 逾期
    assert(FormatTodoRightTimeText("2026-07-20T14:00:00", &now) == "昨天 14:00");
    assert(FormatTodoRightTimeText("2026-07-18", &now) == "逾3天");

    // TickTick +0000 时区格式（UTC 16:00 = 北京时间 00:00 次日）
    // 当前时间 2026-07-21 12:51 本地，dueDate 2026-07-21T16:00:00.000+0000
    // 转为本地时间后是 2026-07-22 00:00 (UTC+8)，即明天
    assert(FormatTodoRightTimeText("2026-07-21T16:00:00.000+0000", &now) == "明天 00:00");

    // 全天任务（is_all_day=true）不显示时间
    assert(FormatTodoRightTimeText("2026-07-21T16:00:00.000+0000", &now, true) == "明天");
    // 全天任务今天到期
    assert(FormatTodoRightTimeText("2026-07-20T16:00:00.000+0000", &now, true) == "今天");
}

} // namespace

int main() {
    TestAsciiWrap();
    TestCjkWrap();
    TestNewlineFlush();
    TestMaxLines();
    TestFormatTodoRightTimeText();
    std::cout << "firmware host tests passed\n";
    return 0;
}
