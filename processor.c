// 文件名: processor.c
#include <stdint.h>

// 宏定义：macOS/Linux 导出符号
#define EXPORT __attribute__((visibility("default")))

// 接收一个字节数组指针和它的长度
EXPORT void process_packet(uint8_t* data, int32_t length) {
    // 遍历数组，将每个字节的值 +1
    for (int i = 0; i < length; i++) {
        data[i] = data[i] + 1;
    }
}