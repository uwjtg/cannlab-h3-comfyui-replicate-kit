#!/usr/bin/env bash
# 安装开机自启钩子到 /home/developer/.bash_profile（持久卷 /home，平台不会覆盖）
set -u
HOME_DIR=/home/developer
PROFILE=$HOME_DIR/.bash_profile
STAMP="# >>> WorkBuddy CANNLab autostart >>>"

if [ -f "$PROFILE" ] && ! grep -qF "$STAMP" "$PROFILE"; then
  cp -a "$PROFILE" "$PROFILE.wbbak"
  echo "BACKED_UP $PROFILE.wbbak"
fi

cat > "$PROFILE" <<'EOF'
# >>> WorkBuddy CANNLab autostart >>>
# 平台每次开机用 /opt/home/developer/ 覆盖 ~/.bashrc 与 ~/.profile，
# 但不会创建 ~/.bash_profile；bash -l 会优先读取它。
# supervisor 的 codearts / devenv / sshd 均以 `bash -l -c` 且 user=developer 启动，
# 所以这个钩子会在环境开机时被触发。后台投递，不阻塞登录 shell。
[ -f "$HOME/.profile" ] && . "$HOME/.profile"
if [ -f /mnt/workspace/auto_start.sh ]; then
    nohup /bin/bash /mnt/workspace/auto_start.sh > /dev/null 2>&1 &
fi
# <<< WorkBuddy CANNLab autostart <<<
EOF
chmod 644 "$PROFILE"
echo "BASH_PROFILE_WRITTEN lines=$(wc -l < "$PROFILE") owner=$(stat -c '%U' "$PROFILE")"
