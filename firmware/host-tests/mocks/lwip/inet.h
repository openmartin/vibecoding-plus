#pragma once
#include <stdint.h>
#include <netinet/in.h>

// Minimal lwIP inet.h mock
#define INADDR_NONE ((uint32_t)0xffffffff)
#define INADDR_ANY ((uint32_t)0x00000000)

uint32_t inet_addr(const char *cp);
char *inet_ntoa(struct in_addr in);
