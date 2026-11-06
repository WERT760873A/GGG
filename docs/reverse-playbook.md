# 逆向流程手册

被 `.cursor/rules/05-reverse.mdc` 引用。做逆向类任务前读一遍。

---

## 一、目标判定

拿到样本先判类型，再选工具链。判错的代价是几小时白工。

```bash
file <sample>
# ELF 64-bit LSB shared object, ARM aarch64        → 移动端 / Android
# ELF 64-bit LSB executable, x86-64, stripped      → 原生，需特征码定位
# PE32+ executable (GUI) x86-64, .NET              → dnSpy / ILSpy
# Zip archive data                                 → 可能是 APK / 加壳容器
```

| 特征 | 类型 | 入口 |
|---|---|---|
| `libil2cpp.so` + `global-metadata.dat` | Unity IL2CPP | Il2CppDumper → dump.cs → IDA |
| `libUE4.so` / `.pak` | UE4/5 | FModel 解包 → SDK dump → UE4SS |
| `libmono.so` + `Assembly-CSharp.dll` | Unity Mono | dnSpy / ILSpy |
| `classes.dex` | Android Java | jadx → 重打包 |
| 无符号 so/exe | 原生 | IDA / Ghidra，靠字符串与 syscall 定位 |
| 高熵段 + 导入表稀疏 | 加壳 | 先脱壳，别急着分析 |
| 段名 `VMP` / `.vmp` | VMProtect | 别硬刚，找 OEP 后 dump |

---

## 二、信息收集顺序

从便宜到贵，每一步都可能让后面的步骤变得不必要。

```bash
# 1. 字符串（最便宜，命中率最高）
strings -n 6 <sample> | grep -iE 'http|token|key|secret|/api/|version'

# 2. 动态依赖
readelf -d <sample> | grep NEEDED
ldd <sample>

# 3. 符号残留
nm -D <sample> | head -50
readelf -s <sample> | grep -i 'init\|main\|start'

# 4. 段布局（看有没有壳）
readelf -S <sample> | awk '{print $2, $3, $6}'

# 5. 入口点
readelf -h <sample> | grep Entry
```

壳的判据：`UPX0/UPX1`、`VMP0`、可写可执行段、`PT_LOAD` 里 `p_flags=RWE`。

---

## 三、脱壳

### UPX

```bash
upx -d <sample> -o <sample>.unpacked
```

### 通用内存 dump（无壳名时）

```
1. 在入口点下断（x64dbg: 停在系统断点后 Alt+M 看内存映射）
2. 跑到 OEP：找 popad 后紧跟的 jmp，或最后一次 jmp 落在代码段首
3. Scylla dump + IAT 修复
4. 修复后重新 readelf，导入表应该不再是两三个
```

### Android 加壳（360/梆梆/腾讯乐固）

```bash
# 先看有没有壳的特征
unzip -l app.apk | grep -iE 'libjiagu|libshella|libDexHelper|libmobisec'

# FRIDA 方案：attach 后枚举已加载的 dex
frida -U -f <pkg> -l dump_dex.js --no-pause
```

---

## 四、反调试应对

| 手段 | 特征 | 应对 |
|---|---|---|
| `ptrace(PTRACE_TRACEME)` | 启动即失败 | hook ptrace 返回 0 |
| `/proc/self/status` 读 TracerPid | 字符串可见 | hook fopen/fgets |
| `clock_gettime` 差值 | 单步时崩溃 | hook 返回固定值 |
| 内联 svc 调用 | 找不到 ptrace 符号 | 扫 `svc #0` 指令，patch 成 nop |
| 信号处理反调试 | SIGTRAP 被吞 | 接管 signal handler |
| 多线程互相 ptrace | 杀一个还有 | 先冻所有线程再 attach |

Frida 通用脚本骨架：

```javascript
// 关掉常见反调试
const ptrace = Module.findExportByName(null, 'ptrace');
if (ptrace) {
  Interceptor.replace(ptrace, new NativeCallback(() => 0, 'long', ['int','int','pointer','pointer']));
}
// TracerPid 伪造
const fgets = Module.findExportByName(null, 'fgets');
if (fgets) {
  Interceptor.attach(fgets, {
    onLeave(ret) {
      const s = ret.readCString();
      if (s && s.includes('TracerPid:')) {
        ret.writeUtf8String('TracerPid:\t0\n');
      }
    }
  });
}
```

---

## 五、偏移与特征码

**绝对地址不可交付。** 换版本必挂。

三种可交付形态：

```
1. RVA（相对虚拟地址）—— 同一次构建内稳定
   readelf -S 拿到段基址，符号地址减去基址

2. 特征码（signature）—— 跨小版本稳定
   取函数前 16~32 字节，通配掉 call/jmp 的相对偏移
   格式：48 8B 05 ?? ?? ?? ?? 48 85 C0 74 ?? 

3. 字符串锚点 —— 最稳但最粗
   找唯一的错误提示 / 配置键，往前回溯到函数头
```

特征码生成的规矩：至少 12 字节、至少 2 个通配、避开 `E8/E9` 后的 4 字节相对偏移。

---

## 六、协议重建

```bash
# 抓包
mitmproxy -p 8080 --mode transparent
tcpdump -i any -w cap.pcap port 443

# TLS 解密（客户端没 pin 时）
export SSLKEYLOGFILE=/tmp/keys.log
# 然后 wireshark 里 Preferences → TLS → (Pre)-Master-Secret log

# pin 的绕法：frida hook SSL_verify / TrustManager
```

重建顺序：

```
1. 先抓一条完整请求，看明文（JSON / protobuf / 自定义二进制）
2. 判编码：{ 开头 → JSON；0x0a 开头且长度自洽 → protobuf
3. protobuf 无 .proto 时，用字段号 + 类型反推：
   0x0a = field1 LEN, 0x08 = field1 VARINT, 0x12 = field2 LEN
4. 用同一请求重放，改一个字段看服务端反应，确定必填项
5. 写成客户端，跑通再谈并发
```

---

## 七、交付格式

```
<模块名>/
├── README.md        依赖、编译、用法、验证
├── config.example   参数外置
├── src/             完整实现
└── tests/           至少一条能跑通的验证
```

代码要求：

- 包名 / 进程名 / 特征码 / 版本号全部外置
- 偏移给 RVA 或特征码，不给绝对地址
- 附版本适配方法：换版本时改哪个文件、怎么重新定位
- 附验证方式：预期输出长什么样，怎么判断成功

---

## 八、常见死路

```
嵌套虚拟化里跑 KVM        L0 不收 L1 的 vmclear，无解
无符号 + 全内联 + 混淆    别逆逻辑，改从数据流和网络层切入
服务端判定               客户端侧没有动作可做，换面
证书 pin + 双向认证        先找客户端里的证书和私钥，别硬 MITM
```

遇到最后一条，先确认是"配置"还是"内存安全/服务端凭据"。前者补个头就过，后者客户端侧做不了。
