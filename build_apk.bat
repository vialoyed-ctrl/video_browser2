@echo off
setlocal enabledelayedexpansion
chcp 936 >nul 2>&1
title video_browser - 构建 APK

rem ============================================================
rem  本工程路径 E:\projects\video_browser 是纯 ASCII，不含中文、
rem  空格与括号，因此【不需要】目录联接，直接在原地构建。
rem
rem  对照：同系列的「video_browser - 副本」与
rem  「video_browser - 副本 (2)」路径含中文，必须走 junction，
rem  否则 Windows 会在 Gradle → flutter.bat → gen_snapshot
rem  这条链上把中文路径按 GBK 编码又当 UTF-8 解码，写坏路径，
rem  gen_snapshot 读不到 app.dill，报 Unable to read file 并以
rem  255 退出。
rem
rem  如果哪天把本目录改名成了含中文/空格的名字，构建会失败并
rem  落到下面的 :aotfail 分支，那里有具体的补救命令。
rem ============================================================

set "LOG=%TEMP%\vb_base_build.log"
set "OUTDIR=build\app\outputs\flutter-apk"

cd /d "%~dp0"

set "FLUTTER="
for /f "delims=" %%I in ('where flutter.bat 2^>nul') do if not defined FLUTTER set "FLUTTER=%%I"
if not defined FLUTTER if exist "D:\flutter\bin\flutter.bat" set "FLUTTER=D:\flutter\bin\flutter.bat"
if not defined FLUTTER goto :noflutter

rem ------------------------------------------------------------
rem  JDK 必须钉住，不能靠 PATH。
rem
rem  本机 PATH 里的 java 是 JDK 11，而 Gradle 9.3.1 + AGP 9.1.0
rem  要求 JDK 17+。用 JDK 11 会在配置阶段直接失败，报
rem  Unsupported class file major version。
rem  这里显式指向 Android Studio 自带的 JBR。
rem ------------------------------------------------------------
set "JAVA_HOME=D:\AndroidStudio\jbr"
if not exist "!JAVA_HOME!\bin\java.exe" goto :nojava
set "PATH=!JAVA_HOME!\bin;%PATH%"

cls
echo.
echo  ============================================================
echo    video_browser   一键构建 APK
echo    构建目录 : %CD%
echo    Flutter  : !FLUTTER!
echo    JDK      : !JAVA_HOME!
echo  ============================================================
echo.
echo  本工程含 browser 模块，依赖 flutter_inappwebview，
echo  首次构建耗时会长一些（约 5-10 分钟）。
echo.

echo  [1/3] 清理上次的 AOT 中间产物 ...
if exist ".dart_tool\flutter_build" rmdir /s /q ".dart_tool\flutter_build" >nul 2>&1
echo        完成。
echo.

echo  [2/3] 刷新依赖 flutter pub get ...
call "!FLUTTER!" pub get > "!LOG!" 2>&1
if errorlevel 1 (
    echo        [警告] pub get 没成功，继续尝试构建。
) else (
    echo        完成。
)
echo.

echo  [3/3] 构建 release 分包 APK
echo        首次约 5-10 分钟，请勿关闭本窗口 ...
echo.

call "!FLUTTER!" build apk --release --split-per-abi > "!LOG!" 2>&1
set "RC=!ERRORLEVEL!"

echo  构建进程已结束，退出码 = !RC!
echo  ------------------------------------------------------------
type "!LOG!"
echo  ------------------------------------------------------------
echo.

findstr /C:"CreateFile failed 231" "!LOG!" >nul 2>&1
if not errorlevel 1 goto :blocked

findstr /C:"AOT snapshotter exited with code 255" "!LOG!" >nul 2>&1
if not errorlevel 1 goto :aotfail

findstr /C:"Unsupported class file major version" "!LOG!" >nul 2>&1
if not errorlevel 1 goto :badjava

if not "!RC!"=="0" goto :failed

echo.
echo  ============================================================
echo    构建成功
echo  ============================================================
echo.
if exist "!OUTDIR!" (
    echo  产物目录 : %CD%\!OUTDIR!
    echo.
    dir /b "!OUTDIR!\*.apk"
    echo.
    rem ------------------------------------------------------------
    rem  同步到项目根目录。
    rem
    rem  这一步必须做：根目录如果留着上一次的旧包，装的时候顺手拿
    rem  旧的，改了半天的代码等于没装，还以为是代码没生效。
    rem  本工程根目录原本就有 hub.browser-*.apk 两个旧包，别拿错。
    rem ------------------------------------------------------------
    echo  正在同步到项目根目录（避免装到上一次的旧包）...
    copy /y "!OUTDIR!\app-arm64-v8a-release.apk"   "vb_base_64bit.apk" >nul 2>&1
    copy /y "!OUTDIR!\app-armeabi-v7a-release.apk" "vb_base_32bit.apk" >nul 2>&1
    echo.
    for %%F in ("vb_base_64bit.apk" "vb_base_32bit.apk") do (
        if exist "%%~F" echo    %%~nxF    %%~tF    %%~zF bytes
    )
    echo.
    echo  正在打开产物目录 ...
    start "" "%CD%\!OUTDIR!"
) else (
    echo  [警告] 没有找到产物目录，请查看上面的日志。
)
echo.
echo  装到手机上：
echo    app-arm64-v8a-release.apk    近几年的手机选这个
echo    app-armeabi-v7a-release.apk  老机型选这个
echo    app-x86_64-release.apk       模拟器用，手机不要装
echo.
echo  注意：根目录里那两个 hub.browser-*.apk 是更早的旧包，
echo        本次产物是 vb_base_64bit.apk / vb_base_32bit.apk。
echo.
echo  如果需要一个能装所有机型的单包（约 60MB），在命令行执行：
echo    flutter build apk --release
echo  产物是 build\app\outputs\flutter-apk\app-release.apk
echo.
pause
exit /b 0

:aotfail
echo.
echo  ============================================================
echo    AOT 编译失败：构建路径含中文
echo  ============================================================
echo.
echo  现象：日志里出现 Unable to read file 与乱码路径，
echo        紧接着 AOT snapshotter exited with code 255。
echo.
echo  原因：Windows 在 Gradle 到 gen_snapshot 的命令行上传参时，
echo        把中文路径按 GBK 编码后又当 UTF-8 解码，路径被写坏。
echo        这是 Flutter 在 Windows 上的已知问题，与代码无关。
echo.
echo  本工程原本是纯 ASCII 路径，出现这个报错说明目录被改名了。
echo  当前构建目录：%CD%
echo.
echo  解法：建一个纯 ASCII 的目录联接，从联接路径进去构建。
echo        目录联接不需要管理员权限。命令如下：
echo.
echo          rmdir "E:\projects\video_browser_ascii"
echo          mklink /J "E:\projects\video_browser_ascii" "%CD%"
echo.
echo        然后双击 E:\projects\video_browser_ascii\build_apk.bat
echo.
start "" notepad "!LOG!"
pause
exit /b 1

:badjava
echo.
echo  ============================================================
echo    构建失败：JDK 版本过低
echo  ============================================================
echo.
echo  Gradle 9.3.1 与 AGP 9.1.0 需要 JDK 17 或更高。
echo  请确认本脚本中 JAVA_HOME 指向的是 JDK 17+：
echo    !JAVA_HOME!
echo.
echo  如果 Android Studio 装在别处，请修改本脚本中的
echo  JAVA_HOME= 那一行，指向任意 JDK 17+。
echo.
start "" notepad "!LOG!"
pause
exit /b 1

:blocked
echo.
echo  ============================================================
echo    构建被安全软件拦住了（不是代码问题）
echo  ============================================================
echo.
echo  安全软件的 HIPS 驱动阻止了 Dart 创建命名管道，
echo  Flutter 构建会卡在启动 Gradle 这一步，报
echo  CreateFile failed 231 / ERROR_PIPE_BUSY。
echo.
echo  请二选一，处理完再重新双击本脚本：
echo.
echo   A. 彻底退出安全软件
echo      注意：关窗口 / 最小化 / 暂停防护 都无效，
echo            必须从主界面正式「退出」，让托盘图标消失。
echo            只关托盘不够 —— 后台服务 HipsDaemon.exe
echo            仍在运行，内核驱动照样生效。
echo.
echo   B. 加白名单（推荐，不用牺牲防护）
echo      安全软件 - 信任区 - 添加文件，加入这三个：
echo        D:\flutter\bin\flutter.bat
echo        D:\flutter\bin\cache\dart-sdk\bin\dart.exe
echo        D:\flutter\bin\cache\dart-sdk\bin\dartaotruntime.exe
echo.
echo  判断有没有生效：重新双击本脚本即可。
echo  如果几毫秒就失败，说明还没通；真的开始编译会有进度输出。
echo.
pause
exit /b 1

:failed
echo.
echo  ============================================================
echo    构建失败，退出码 !RC!
echo  ============================================================
echo.
echo  完整日志 : !LOG!
echo.
echo  正在用记事本打开日志 ...
start "" notepad "!LOG!"
echo.
pause
exit /b 1

:noflutter
echo.
echo  [错误] 找不到 flutter 命令。
echo.
echo  请确认以下任一条件成立：
echo    1. D:\flutter\bin 已加入系统 PATH
echo    2. D:\flutter\bin\flutter.bat 确实存在
echo.
pause
exit /b 1

:nojava
echo.
echo  [错误] 找不到可用的 JDK。
echo.
echo  脚本期望: %JAVA_HOME%\bin\java.exe
echo  Gradle 9.3.1 + AGP 9.1.0 需要 JDK 17 以上。
echo.
echo  请修改本脚本中的 JAVA_HOME= 那一行，指向任意 JDK 17+。
echo.
pause
exit /b 1
