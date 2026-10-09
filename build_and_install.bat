@echo off
setlocal enabledelayedexpansion
chcp 936 >nul 2>&1
title video_browser - 构建并安装到手机

rem ============================================================
rem  video_browser 一键「编译 + 装机」
rem
rem  与 build_apk.bat 的分工：
rem    build_apk.bat          只编译，产物丢到根目录，自己手动装
rem    build_and_install.bat  编译 + 自动探测手机 + 覆盖安装 + 拉起 App
rem
rem  用法：
rem    build_and_install.bat            编译分包 APK 并装机（默认）
rem    build_and_install.bat universal  编译通用单包约 60MB 并装机
rem
rem  本工程路径 E:\projects\video_browser 是纯 ASCII，不含中文、空格
rem  与括号，可以直接原地构建。若目录被改名成含中文/空格的名字，
rem  构建会落到下面的 :aotfail 分支，那里有补救命令。
rem ============================================================

set "LOG=%TEMP%\vb_build_install.log"
set "OUTDIR=build\app\outputs\flutter-apk"
set "PKG=com.example.video_browser"
set "ACT=com.example.video_browser.MainActivity"

set "UNIVERSAL=0"
if /i "%~1"=="universal" set "UNIVERSAL=1"

cd /d "%~dp0"

rem ------------------------------------------------------------
rem  Flutter 定位：优先 PATH，其次 D:\flutter
rem ------------------------------------------------------------
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

set "BUILDMODE=--split-per-abi"
if "!UNIVERSAL!"=="1" set "BUILDMODE="

cls
echo.
echo  ============================================================
echo    video_browser   构建 + 装机
echo    构建目录 : %CD%
echo    Flutter  : !FLUTTER!
echo    JDK      : !JAVA_HOME!
echo    构建模式 : !BUILDMODE!
if "!BUILDMODE!"=="" echo    构建模式 : 通用单包 universal
echo  ============================================================
echo.

echo  [1/4] 清理上次的 AOT 中间产物 ...
if exist ".dart_tool\flutter_build" rmdir /s /q ".dart_tool\flutter_build" >nul 2>&1
echo        完成。
echo.

echo  [2/4] 刷新依赖 flutter pub get ...
call "!FLUTTER!" pub get > "!LOG!" 2>&1
if errorlevel 1 (
    echo        [警告] pub get 没成功，继续尝试构建。
) else (
    echo        完成。
)
echo.

echo  [3/4] 构建 release APK ...
echo        首次约 5-10 分钟，请勿关闭本窗口 ...
echo.
call "!FLUTTER!" build apk --release !BUILDMODE! > "!LOG!" 2>&1
set "RC=!ERRORLEVEL!"
echo        构建进程已结束，退出码 = !RC!
echo.

rem  按日志内容分流到具体的失败原因，比只看退出码有用得多
findstr /C:"CreateFile failed 231" "!LOG!" >nul 2>&1
if not errorlevel 1 goto :blocked
findstr /C:"AOT snapshotter exited with code 255" "!LOG!" >nul 2>&1
if not errorlevel 1 goto :aotfail
findstr /C:"Unsupported class file major version" "!LOG!" >nul 2>&1
if not errorlevel 1 goto :badjava
if not "!RC!"=="0" goto :failed

echo  ============================================================
echo    构建成功
echo  ============================================================
echo.
dir /b "!OUTDIR!\*.apk"
echo.

rem ------------------------------------------------------------
rem  同步到项目根目录。
rem
rem  这一步必须做：根目录如果留着上一次的旧包，装的时候顺手拿旧的，
rem  改了半天的代码等于没装，还以为是代码没生效。
rem ------------------------------------------------------------
copy /y "!OUTDIR!\app-arm64-v8a-release.apk"   "vb_base_64bit.apk" >nul 2>&1
copy /y "!OUTDIR!\app-armeabi-v7a-release.apk" "vb_base_32bit.apk" >nul 2>&1

echo  [4/4] 安装到手机 ...
echo.

set "ADB="
for /f "delims=" %%I in ('where adb.exe 2^>nul') do if not defined ADB set "ADB=%%I"
if not defined ADB goto :noadb

rem  取第一台状态为 device 的手机。skip=1 跳过 "List of devices attached"
set "DEV="
set "DEVN=0"
for /f "skip=1 tokens=1,2" %%D in ('adb devices') do (
    if "%%E"=="device" (
        set /a DEVN+=1
        if not defined DEV set "DEV=%%D"
    )
)
if not defined DEV goto :nodevice
if !DEVN! GTR 1 echo        [注意] 检测到 !DEVN! 台设备，只用第一台。

rem  按手机 CPU 架构挑对应的分包
set "ABI="
for /f "delims=" %%A in ('adb -s !DEV! shell getprop ro.product.cpu.abi 2^>nul') do set "ABI=%%A"

set "APK=!OUTDIR!\app-arm64-v8a-release.apk"
if /i "!ABI!"=="armeabi-v7a" set "APK=!OUTDIR!\app-armeabi-v7a-release.apk"
if /i "!ABI!"=="x86_64"      set "APK=!OUTDIR!\app-x86_64-release.apk"
if "!UNIVERSAL!"=="1"        set "APK=!OUTDIR!\app-release.apk"

echo        设备序列号 : !DEV!
echo        设备架构   : !ABI!
echo        安装文件   : !APK!
echo.
echo        正在覆盖安装，保留 App 数据 ...
echo.
adb -s !DEV! install -r "!APK!"
if errorlevel 1 goto :instfail

echo.
echo        拉起 App ...
adb -s !DEV! shell am start -n !PKG!/!ACT! >nul 2>&1
echo.
echo  ============================================================
echo    完成 —— 手机上已经是最新版本
echo  ============================================================
echo.
pause
exit /b 0

rem ============================================================
rem  以下是失败分支
rem ============================================================

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
echo        然后双击 E:\projects\video_browser_ascii\build_and_install.bat
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
echo    构建被安全软件拦住了，不是代码问题
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
echo   B. 加白名单，推荐，不用牺牲防护
echo      安全软件 - 信任区 - 添加文件，加入这三个：
echo        D:\flutter\bin\flutter.bat
echo        D:\flutter\bin\cache\dart-sdk\bin\dart.exe
echo        D:\flutter\bin\cache\dart-sdk\bin\dartaotruntime.exe
echo.
echo  判断有没有生效：重新双击本脚本即可。
echo  如果几毫秒就失败，说明还没通；真的开始编译会有进度输出。
echo.
start "" notepad "!LOG!"
pause
exit /b 1

:failed
echo.
echo  ============================================================
echo    构建失败，退出码 !RC!
echo  ============================================================
echo.
echo  完整日志已写入：!LOG!
echo  下面用记事本打开它，搜索 error / FAILURE 定位第一条真实报错。
echo.
start "" notepad "!LOG!"
pause
exit /b 1

:instfail
echo.
echo  ============================================================
echo    安装失败
echo  ============================================================
echo.
echo  最常见的原因：手机上已装的版本签名与本包不同。
echo  报错形如 INSTALL_FAILED_UPDATE_INCOMPATIBLE。
echo.
echo  两种解法，任选其一：
echo.
echo   A. 先卸载再装。注意会清掉 App 数据，观看记录与稍后再看会没
echo        adb -s !DEV! uninstall !PKG!
echo      然后重新双击本脚本
echo.
echo   B. 尝试保留数据安装，部分机型支持
echo        adb -s !DEV! install -r -d "!APK!"
echo.
echo  其他可能：手机存储空间不足、手机上弹了「拒绝安装」。
echo.
echo  编译产物本身没问题，在：
echo    %CD%\!OUTDIR!
echo.
pause
exit /b 1

:nodevice
echo.
echo        [跳过安装] 没有检测到已连接且已授权的手机。
echo.
echo        编译产物已经生成好了，在：
echo          %CD%\!OUTDIR!
echo.
echo        插上手机、打开「USB 调试」并在手机上点「允许」之后，
echo        重新双击本脚本即可只走安装这一步。
echo        只想编译不装机的话，用 build_apk.bat。
echo.
pause
exit /b 0

:noadb
echo.
echo        [跳过安装] 没找到 adb.exe，它不在 PATH 里。
echo.
echo        编译产物已生成：%CD%\!OUTDIR!
echo.
echo        手动装：
echo          adb install -r "build\app\outputs\flutter-apk\app-arm64-v8a-release.apk"
echo.
pause
exit /b 0

:noflutter
echo.
echo  ============================================================
echo    找不到 flutter.bat
echo  ============================================================
echo.
echo  本脚本先查 PATH，再查 D:\flutter\bin\flutter.bat，都没有找到。
echo  请修改本脚本开头的 FLUTTER 探测那两行，指向你的实际安装位置。
echo.
pause
exit /b 1

:nojava
echo.
echo  ============================================================
echo    找不到 JDK
echo  ============================================================
echo.
echo  本脚本期望的 JAVA_HOME 是：
echo    !JAVA_HOME!
echo.
echo  但该目录下没有 bin\java.exe。
echo  请修改本脚本中 JAVA_HOME= 那一行，指向任意 JDK 17+，
echo  例如 Android Studio 自带的 jbr 目录。
echo.
pause
exit /b 1
