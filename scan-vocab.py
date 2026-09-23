#!/usr/bin/env python3
"""從你已經寫過的文件裡挖出常用的專有名詞，提議加進詞彙表。

為什麼不攔截鍵盤：那會把密碼、私訊、金融資料全部錄下來。
你電腦裡本來就有一堆你親手打的字，那是同樣準確而且零風險的樣本來源。

用法：
  scan-vocab.py ~/Desktop            掃描並列出候選詞
  scan-vocab.py ~/Desktop --add      直接加進詞彙表
"""
import collections
import json
import os
import re
import sys

HOME = os.path.expanduser("~")
VOCAB = os.path.join(HOME, ".config/voicetype/corrections.txt")
HISTORY = os.path.join(HOME, ".cache/voicetype/history.jsonl")

# 中文常見詞：出現頻率高但不是專有名詞，放進來會稀釋熱詞表
STOP = set("""
的了是在我有和就不人都一個上也很到說要去你會著沒有看好自己這那
我們你們他們可以應該因為所以但是如果然後就是這個那個什麼怎麼為什麼
時候地方東西問題方式功能系統資料檔案內容部分方面情況狀況
可能需要應該已經還是或是以及等等之類其他另外目前現在剛剛
一下一點一些這樣那樣怎樣如何多少幾個第一第二第三
""".split())

# 這些詞形很像專有名詞但其實是通用技術詞，幫使用者省掉手動剔除
GENERIC_EN = set("""
true false null none void int str dict list json html http https www com org net
function return const let var class import export default async await
""".split())

CJK = r"一-鿿"


def read_docs(roots, max_files=400):
    """只讀使用者自己寫的文件。

    第一版把專案裡的 LICENSE、CHANGELOG 也算進去，結果前 30 名全是
    WARRANTIES、Copyright、INCLUDING 這類授權樣板字。
    判斷「這是不是他寫的」最好用的訊號是中文比例——他的筆記幾乎都有中文，
    第三方的英文文件沒有。
    """
    skip_dir = re.compile(r"/(node_modules|\.git|venv|__pycache__|build|dist|vendor|"
                          r"wp-content|wp-includes|wp-admin|Library|\.cache|site-packages)/")
    skip_file = re.compile(r"^(LICEN[CS]E|CHANGELOG|COPYING|NOTICE|AUTHORS|CONTRIBUTING)",
                           re.I)
    texts, files = [], 0
    for root in roots:
        for dirpath, dirnames, filenames in os.walk(os.path.expanduser(root)):
            if skip_dir.search(dirpath + "/"):
                dirnames[:] = []
                continue
            for fn in filenames:
                if not fn.endswith((".md", ".txt")) or skip_file.match(fn):
                    continue
                p = os.path.join(dirpath, fn)
                try:
                    if os.path.getsize(p) < 500 or os.path.getsize(p) > 2_000_000:
                        continue
                    with open(p, encoding="utf-8", errors="ignore") as f:
                        t = f.read()
                    # 中文少於 8% 的，多半是第三方英文文件，不是他寫的
                    cjk = len(re.findall(rf"[{CJK}]", t))
                    if cjk < len(t) * 0.08 or cjk < 200:
                        continue
                    texts.append(t)
                    files += 1
                    if files >= max_files:
                        return texts, files
                except OSError:
                    pass
    return texts, files


def candidates(text):
    """抽出可能是專有名詞的詞。

    回傳 (counts, quoted)。quoted 是被「」『』【】《》框起來的詞——
    作者刻意標記的，是「這是專有名詞」最強的訊號。
    """
    counts = collections.Counter()
    quoted = collections.Counter()

    # 一、引號或書名號裡的詞——作者刻意標記出來的，命中率最高
    for m in re.finditer(rf"[「『【《]([{CJK}A-Za-z0-9]{{2,10}})[」』】》]", text):
        counts[m.group(1)] += 3          # 加權：這種訊號最強
        quoted[m.group(1)] += 1

    # 二、英數混合或大寫開頭的字（品牌、產品、技術名）
    for m in re.finditer(r"\b([A-Z][A-Za-z0-9]{2,19}|[A-Za-z]{2,}[0-9]+[A-Za-z0-9]*)\b", text):
        w = m.group(1)
        # 全大寫多半是常數或授權樣板（THE、ANY、WARRANTIES），不是品牌名
        if w.isupper() and len(w) > 2:
            continue
        if w.lower() not in GENERIC_EN:
            counts[w] += 1

    # 三、重複出現的中文 2-4 字組合
    #     沒有斷詞器，用「反覆出現且不在停用詞裡」當近似
    for n in (4, 3, 2):
        for m in re.finditer(rf"[{CJK}]{{{n}}}", text):
            w = m.group(0)
            if w not in STOP and not any(c in STOP for c in [w]):
                counts[w] += 1
    return counts, quoted


def already_known(vocab_path):
    known = set()
    try:
        for line in open(vocab_path, encoding="utf-8"):
            t = line.strip()
            if not t or t.startswith("#"):
                continue
            known.add(t.split("→")[-1].split("->")[-1].strip())
            known.add(t.split("→")[0].split("->")[0].strip())
    except OSError:
        pass
    return known


def spoken_terms(history_path):
    """口述紀錄裡已經正確出現過的詞——這些不用加，辨識本來就對。"""
    out = []
    try:
        for line in open(history_path, encoding="utf-8"):
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line).get("out", ""))
                except json.JSONDecodeError:
                    pass
    except OSError:
        pass
    return "\n".join(out)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    roots = args or ["~/Desktop"]
    do_add = "--add" in sys.argv
    top_n = 30

    texts, nfiles = read_docs(roots)
    if not texts:
        print("找不到可掃描的文件"); return
    blob = "\n".join(texts)

    counts, quoted = candidates(blob)
    known = already_known(VOCAB)
    spoken = spoken_terms(HISTORY)

    ranked = []
    for w, c in counts.most_common(5000):
        if c < 4 or w in known or len(w) < 2:
            continue
        # 口述紀錄裡出現過就代表辨識本來就對，不用佔熱詞表的位置（只有 40 個名額）
        if spoken.count(w) >= 1:
            continue
        is_cjk = bool(re.match(rf"^[{CJK}]+$", w))
        # 兩個字的中文詞絕大多數是通用詞（完整、內容、時間），辨識不會錯。
        # 除非作者用「」框過它——那就是他刻意標記的專有名詞。
        if is_cjk and len(w) == 2 and quoted[w] == 0:
            continue
        ranked.append((w, c, quoted[w]))
        if len(ranked) >= top_n:
            break

    if not ranked:
        print("沒有找到新的候選詞——你的詞彙表已經涵蓋常用的了。")
        return

    print(f"掃描了 {nfiles} 個檔案、{len(blob):,} 字元\n")
    print(f"{'候選詞':<16}{'出現次數':>8}{'被引號框過':>10}")
    print("-" * 38)
    for w, c, q in ranked:
        print(f"{w:<16}{c:>8}{q:>10}")

    if do_add:
        with open(VOCAB, "a", encoding="utf-8") as f:
            f.write("\n".join(w for w, _, _ in ranked) + "\n")
        print(f"\n已加入 {len(ranked)} 個詞。跑 vt.sh sync 同步到手機。")
    else:
        print(f"\n這些只是提議。確認要加就跑：")
        print(f"  {sys.argv[0]} {' '.join(roots)} --add")
        print("或自己挑幾個貼進設定視窗的詞彙表。")


if __name__ == "__main__":
    main()
