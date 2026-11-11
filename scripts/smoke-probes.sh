# shellcheck shell=bash
# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
#
# 变量别叫 state：shellcheck 把这份文件连着 probes.sh 一起分析，probes.sh 自己也读一个 dev.sh 提供的 state；
# 子壳体函数（fn() ( … )）里给 state 赋值，SC2031 就报在 probes.sh 上，CI 红。
#
# grocy：sso=proxy（网关注入 Remote-User，grocy 按它认人、没有的用户自动建号）。清单没有 mcp。
# 代登录下应用没有自己的登录页可走：核心会话 Cookie 就是全部——dweb --sso 从插件入口出发把核心
# 登录页的 JS 自动表单跟完，之后同一 jar 的请求经网关都会带上 Remote-User。
# 数据钩子跑在第一次会话建立之前，所以每个钩子都先 dweb --sso 建一次会话。
#
# 变量：SMOKE_WEB_URL 是应用的网页入口（套件已去尾斜杠）；拼 API 路径用 SMOKE_WEB_ORIGIN
#（只有 scheme://host:port，入口的路径不掺进来），别直接接在 SMOKE_WEB_URL 后面。

web_assert() { grep -qi 'grocy'; }   # 库存概览页的页脚和侧栏都有 grocy 品牌

grocy_session() { # 核心会话就绪（已建立就原地返回，失败时输出便于排查）
	if [[ -z "${SMOKE_WEB_URL:-}" ]]; then
		# 单独跑 dev.sh probes data_check 时套件还没备好网页地址，这里补上
		probes_web_url || { echo "拿不到插件网页地址"; return 1; }
	fi
	if [[ -s "${SMOKE_JAR:-}" ]] && grep -q 'wonton' "$SMOKE_JAR" 2>/dev/null; then
		return 0
	fi
	dweb --sso / >/dev/null 2>&1
}

identity_check() { # 应用自己的“当前用户”接口认出的是主人
	local resp
	grocy_session || { echo "核心会话建立失败"; return 1; }
	resp="$(web_get /api/user -H 'Accept: application/json')" ||
		{ echo "GET /api/user 失败：$(head -c 200 <<<"$resp")"; return 1; }
	jq -e --arg u "$SMOKE_OWNER" 'type == "array" and length == 1 and .[0].username == $u' <<<"$resp" >/dev/null ||
		{ echo "当前用户不是 $SMOKE_OWNER：$(head -c 300 <<<"$resp")"; return 1; }
}

marker_file() { # SMOKE_STATE 在冒烟套件里是目录、在 e2e 里是文件，标记放它旁边，两种都能用
	if [[ -d "$SMOKE_STATE" ]]; then
		printf '%s' "$SMOKE_STATE/grocy-marker"
	else
		printf '%s' "${SMOKE_STATE}.grocy-marker"
	fi
}

data_write() { # 在购物清单写一条带随机标记的备注项，标记存进 $SMOKE_STATE（覆盖写）
	local marker resp
	grocy_session || { echo "核心会话建立失败"; return 1; }
	marker="wonton-smoke-$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
	resp="$(web_get /api/objects/shopping_list -X POST -H 'Content-Type: application/json' \
		--data "{\"note\":\"$marker\"}")" ||
		{ echo "建购物清单项失败：$(head -c 200 <<<"$resp")"; return 1; }
	jq -e '.created_object_id' <<<"$resp" >/dev/null 2>&1 ||
		{ echo "购物清单项没建成：$(head -c 200 <<<"$resp")"; return 1; }
	printf '%s\n' "$marker" >"$(marker_file)"
}

data_check() { # 按标记读回购物清单项
	local marker resp
	marker="$(cat "$(marker_file)" 2>/dev/null)"
	[[ -n "$marker" ]] || { echo "SMOKE_STATE 标记文件是空的（data_write 没跑过？）"; return 1; }
	grocy_session || { echo "核心会话建立失败"; return 1; }
	resp="$(web_get /api/objects/shopping_list -H 'Accept: application/json')" ||
		{ echo "读购物清单失败：$(head -c 200 <<<"$resp")"; return 1; }
	jq -e --arg n "$marker" 'type == "array" and any(.[]; .note == $n)' <<<"$resp" >/dev/null ||
		{ echo "标记项不见了，清单内容：$(head -c 300 <<<"$resp")"; return 1; }
}
