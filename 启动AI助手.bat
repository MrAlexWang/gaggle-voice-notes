@echo off
chcp 65001 >nul
title 雁书 AI 助手（A2A Server）
cd /d "%~dp0tools"

echo ============================================
echo    雁书 AI 助手
echo ============================================
echo.

if not exist "agent_config.json" (
  if exist "agent_config.example.json" (
    copy /y "agent_config.example.json" "agent_config.json" >nul
    echo [提示] 已从 agent_config.example.json 生成 agent_config.json
  )
)
if not exist "agent_config.json" (
  echo [错误] 找不到 agent_config.json
  pause
  exit /b
)

echo 当前配置：
python -c "import json;c=json.load(open('agent_config.json',encoding='utf-8'));print('  服务地址:',c['base_url']);print('  模型:',c['model']);print('  API Key:','已填写' if c['api_key'] else '【未填写】')"
echo.

python -c "import json,sys;c=json.load(open('agent_config.json',encoding='utf-8'));sys.exit(0 if (c['api_key'] or '127.0.0.1' in c['base_url']) else 1)"
if errorlevel 1 (
  echo ----------------------------------------------------
  echo  [!] 还没配置 API Key，AI 无法真正回答
  echo.
  echo  两种选择（编辑 tools\agent_config.json）：
  echo.
  echo  A. 用云端（推荐，最快，几秒配好）
  echo     注册 https://platform.deepseek.com 拿 key
  echo     然后填 "api_key": "sk-你的key"
  echo.
  echo  B. 用本地 Ollama（完全离线，但要先装）
  echo     1) 安装 Ollama：https://ollama.com/download
  echo     2) 命令行执行：ollama pull qwen2.5:3b
  echo     3) 把配置改成：
  echo        "base_url": "http://127.0.0.1:11434/v1"
  echo        "api_key": "ollama"
  echo        "model": "qwen2.5:3b"
  echo ----------------------------------------------------
  echo.
  pause
)

echo 正在启动（保持此窗口开启，关闭即停止 AI 能力）...
echo.
python agent_llm.py
pause
