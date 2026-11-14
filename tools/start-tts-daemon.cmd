@echo off
rem 启动本地音色守护进程（可选能力，没有也能用，只是语音退化为纯文字）。
rem 需要 Python 3.11 + voice-env 虚拟环境，并把 VOICE_HOME 指向放 tts_daemon.py 的目录。
if "%VOICE_HOME%"=="" (
  echo [error] 请先设置 VOICE_HOME 为你自己的语音工程目录
  exit /b 1
)
if not exist "%VOICE_HOME%\logs" mkdir "%VOICE_HOME%\logs"
start "" /b "%VOICE_HOME%\env\Scripts\pythonw.exe" "%VOICE_HOME%\tts_daemon.py" >> "%VOICE_HOME%\logs\daemon.log" 2>&1
exit /b 0
