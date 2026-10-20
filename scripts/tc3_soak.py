#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
TC3 연속 요청(운영 가능성) 시험 스크립트
- OpenAI 호환 API(/v1/chat/completions)에 N회 순차 요청을 보내 성공률과 응답시간(p50/p95/max)을 집계한다.
- vLLM(1안 L40S)과 furiosa-llm(2안 RNGD) 모두 동일하게 사용 가능.
- 의존성: python3 (3.8+), requests  (pip install requests)

사용 예:
  python3 tc3_soak.py --url http://<VM_IP>:8000 --n 100
  python3 tc3_soak.py --url http://<VM_IP>:8000 --n 100 --model Llama-3.1-8B-Instruct --out tc3_soak_result.csv
"""
import argparse
import csv
import datetime as dt
import json
import math
import statistics
import sys
import time

try:
    import requests
except ImportError:
    sys.exit("requests 모듈이 필요합니다: pip install requests")

# 연속 요청 데이터셋: 한국어 50 + 영어 50 = 서로 다른 100문항 (10개 유형 × 5문항 × 2개 언어), 한/영을 번갈아 보낸다.
#   N > 100 이면 처음부터 다시 돈다. 응답 전문은 --answers 파일(soak_answers.jsonl)에 남는다.
KO = {
    "사실": ["대한민국의 수도는 어디인가요? 한 문장으로 답하세요.", "한글을 만든 조선의 왕은 누구인가요? 한 문장으로 답하세요.",
             "태양계에서 가장 큰 행성은 무엇인가요? 짧게 답하세요.", "제주도의 대표적인 화산 지형 하나를 알려 주세요.",
             "신라의 수도였던 도시는 어디인가요?"],
    "설명": ["인공지능 반도체(NPU)가 무엇인지 두 문장으로 설명해 주세요.", "클라우드 컴퓨팅의 장점 두 가지를 간단히 설명해 주세요.",
             "대형 언어 모델에서 '토큰'이 무엇인지 쉽게 설명해 주세요.", "가상 머신과 컨테이너의 차이를 한 문장으로 설명해 주세요.",
             "오픈소스 소프트웨어의 장점을 한 문장으로 말해 주세요."],
    "번역": ['다음 문장을 영어로 번역하세요: "오늘은 날씨가 맑고 따뜻합니다."', '다음 문장을 영어로 번역하세요: "회의는 오후 세 시에 시작합니다."',
             '다음 문장을 영어로 번역하세요: "이 모델은 한국어와 영어를 모두 이해합니다."', '다음 문장을 영어로 번역하세요: "도서관에서 책 두 권을 빌렸어요."',
             '다음 문장을 영어로 번역하세요: "기차가 십 분 늦게 도착했습니다."'],
    "요약": ['다음 글을 한 문장으로 요약하세요: "봄이 되면 벚꽃이 피고 많은 사람들이 공원으로 나들이를 갑니다. 주말에는 공원이 붐빕니다."',
             '한 문장으로 요약하세요: "회사는 새 서버를 도입해 처리 속도를 두 배로 높였고 전력 사용량은 30% 줄였다."',
             '한 문장으로 요약하세요: "운동은 심장 건강을 돕고 스트레스를 줄이며 잠을 잘 자게 해 준다."',
             '한 문장으로 요약하세요: "그 도시는 지하철 노선을 늘리고 버스 배차 간격을 줄여 출퇴근 시간이 짧아졌다."',
             '한 문장으로 요약하세요: "학생들은 자료를 조사하고 발표 자료를 만들어 수업 시간에 발표했다."'],
    "수학": ["사과 3개와 배 5개가 있습니다. 과일은 모두 몇 개인가요? 숫자로 답하세요.", "시속 60km로 2시간 30분을 달리면 몇 km를 가나요?",
             "240의 15%는 얼마인가요?", "1부터 10까지 더하면 얼마인가요?", "한 변이 7cm인 정사각형의 넓이는 얼마인가요?"],
    "추론": ["철수는 영희보다 키가 크고, 영희는 민수보다 키가 큽니다. 가장 키가 큰 사람은 누구인가요?", "오늘이 월요일이면 3일 뒤는 무슨 요일인가요?",
             "모든 고양이는 동물이고 나비는 고양이입니다. 나비는 동물인가요? 이유와 함께 한 문장으로 답하세요.",
             "상자에 빨간 공 2개와 파란 공 3개가 있습니다. 하나를 꺼낼 때 파란 공일 확률은?", "지금 오후 11시입니다. 3시간 뒤는 몇 시인가요?"],
    "코딩": ["파이썬으로 두 수의 합을 반환하는 함수를 한 줄로 작성해 주세요.", "파이썬에서 리스트를 뒤집는 방법 하나를 알려 주세요.",
             "리눅스에서 현재 디렉터리의 파일 목록을 보는 명령어는 무엇인가요?", "JSON이 무엇인지 한 문장으로 설명해 주세요.",
             "파이썬에서 문자열의 길이를 구하는 함수는 무엇인가요?"],
    "분류": ['다음 문장의 감정을 긍정 또는 부정으로 분류하세요: "이 영화 정말 재미있었어요!"',
             '다음 문장의 감정을 긍정 또는 부정으로 분류하세요: "배송이 너무 늦어서 실망했습니다."',
             "다음 중 과일이 아닌 것은? 사과, 바나나, 당근, 포도", "고래는 어류인가요, 포유류인가요? 한 단어로 답하세요.",
             "다음 중 프로그래밍 언어는 무엇인가요? 파이썬, 김치, 서울"],
    "작문": ["가을을 주제로 짧은 시 한 줄을 지어 주세요.", "새해 인사말을 한 문장으로 써 주세요.", "동료에게 보내는 감사 메시지를 한 문장으로 써 주세요.",
             "'노력'을 주제로 짧은 격언을 하나 만들어 주세요.", "동네 카페 홍보 문구를 한 문장으로 만들어 주세요."],
    "과학": ["1기압에서 물이 끓는 온도는 섭씨 몇 도인가요?", "식물이 광합성에 필요한 기체는 무엇인가요?",
             "지구가 태양 주위를 한 바퀴 도는 데 걸리는 시간은 얼마인가요?", "빛의 속도는 대략 초속 몇 km인가요?",
             "사람의 몸에서 가장 큰 장기는 무엇인가요?"],
}
EN = {
    "fact": ["What is the capital of France? Answer in one sentence.", 'Who wrote "Romeo and Juliet"? Answer briefly.',
             "What is the largest ocean on Earth?", "In which year did humans first land on the Moon?", "What is the chemical symbol for gold?"],
    "explain": ["Explain in two sentences what a neural processing unit (NPU) does.", "Briefly explain what an operating system is.",
                "What is the difference between RAM and storage? Answer in one sentence.", "Explain what an API is in simple terms.",
                "Why is open-source software useful? Answer in one sentence."],
    "translate": ['Translate into Korean: "Good morning, how are you?"', 'Translate into Korean: "The server is running normally."',
                  'Translate into Korean: "Please send me the report by Friday."', 'Translate into Korean: "I would like a cup of coffee."',
                  'Translate into Korean: "The test finished successfully."'],
    "summarize": ['Summarize in one sentence: "The company released a new chip that is faster and uses less power than the previous model."',
                  'Summarize in one sentence: "Heavy rain delayed several train lines this morning, but service is now back to normal."',
                  'Summarize in one sentence: "The library extended its opening hours and added study rooms for students during exam season."',
                  'Summarize in one sentence: "Researchers found that short daily walks improve mood and help people sleep better."',
                  'Summarize in one sentence: "The team fixed the bug, added tests, and deployed the update to all servers."'],
    "math": ["What is 17 multiplied by 6?", "A train travels 120 km in 1.5 hours. What is its average speed?", "What is 25% of 240?",
             "If x + 7 = 19, what is x?", "What is the area of a rectangle that is 8 m by 5 m?"],
    "reasoning": ["Tom is older than Ann, and Ann is older than Ben. Who is the youngest?", "If today is Friday, what day will it be in 4 days?",
                  "All roses are flowers and some flowers fade quickly. Can we conclude that all roses fade quickly? Answer yes or no and explain briefly.",
                  "A box has 4 red and 6 blue balls. What is the probability of picking a red ball?", "It is 9:45 now. What time will it be in 30 minutes?"],
    "code": ["Write a one-line Python function that returns the square of a number.", 'How do you print "Hello, world" in Python?',
             'What does the Linux command "pwd" do?', "Write a SQL query that selects all rows from a table named users.",
             "What is the time complexity of binary search?"],
    "classify": ['Classify the sentiment as positive or negative: "I love this phone, the battery lasts all day."',
                 'Classify the sentiment as positive or negative: "The service was slow and the food was cold."',
                 "Which word does not belong: apple, banana, carrot, grape?", "Is a dolphin a fish or a mammal? Answer in one word.",
                 "In software, is Python a programming language or an animal?"],
    "write": ["Write a one-line poem about the ocean.", "Write a short thank-you message to a colleague.",
              "Write a one-sentence slogan for a smart watch.", "Write a friendly one-sentence reminder about a team meeting at 3 PM.",
              "Give one tip for staying productive while working from home."],
    "science": ["At what temperature does water freeze in Celsius?", "What gas do humans need to breathe to survive?",
                "What force keeps the planets in orbit around the Sun?", "What is the boiling point of water in Fahrenheit?",
                "Which part of the cell contains genetic material?"],
}


def _dataset():
    ko = [("KO", c, q) for c, qs in KO.items() for q in qs]
    en = [("EN", c, q) for c, qs in EN.items() for q in qs]
    # 유형이 섞이도록 5칸씩 건너뛰며 고르고, 한/영을 번갈아 배치
    order = [i for s in range(5) for i in range(s, len(ko), 5)]
    out = []
    for i in order:
        out += [ko[i], en[i]]
    return out


PROMPTS = _dataset()   # 100개 (서로 다름)


def percentile(sorted_vals, p):
    """nearest-rank 백분위: N=100 → 95번째 값, N=10 → 10번째(최댓값)."""
    if not sorted_vals:
        return float("nan")
    k = max(0, min(len(sorted_vals) - 1, math.ceil(p / 100.0 * len(sorted_vals)) - 1))
    return sorted_vals[k]


def main():
    ap = argparse.ArgumentParser(description="TC3 연속 요청 시험")
    ap.add_argument("--url", required=True, help="서버 주소, 예: http://10.0.0.12:8000")
    ap.add_argument("--model", default="Llama-3.1-8B-Instruct", help="served-model-name")
    ap.add_argument("--n", type=int, default=100, help="요청 횟수 (기본 100)")
    ap.add_argument("--max-tokens", type=int, default=96)
    ap.add_argument("--timeout", type=float, default=60.0)
    ap.add_argument("--out", default="tc3_soak_result.csv", help="요청별 결과 CSV")
    ap.add_argument("--answers", default="", help="요청·응답 전문 JSONL (기본: --out 옆 soak_answers.jsonl)")
    ap.add_argument("--summary-json", default="", help="요약(JSON) 저장 경로 — 시도마다 새로 씀")
    a = ap.parse_args()
    if a.n < 1:
        sys.exit("--n 은 1 이상이어야 합니다")

    endpoint = a.url.rstrip("/") + "/v1/chat/completions"
    started = dt.datetime.now()
    print(f"# TC3 soak test  start={started:%Y-%m-%d %H:%M:%S}  url={endpoint}  model={a.model}  n={a.n}", flush=True)
    print(f"# dataset: 서로 다른 {len(PROMPTS)}문항 (한국어 {sum(p[0] == 'KO' for p in PROMPTS)} + 영어 {sum(p[0] == 'EN' for p in PROMPTS)}, "
          f"{len(KO)}개 유형) · max_tokens={a.max_tokens} · temperature=0", flush=True)
    sess = requests.Session()
    if "//127.0.0.1" in endpoint or "//localhost" in endpoint:
        sess.trust_env = False  # 로컬 서버 호출이 http_proxy 로 새지 않도록
    import os
    ans_path = a.answers or os.path.join(os.path.dirname(os.path.abspath(a.out)), "soak_answers.jsonl")
    ans_f = open(ans_path, "w", encoding="utf-8")

    rows, lat, lat_ok, ok = [], [], [], 0
    for i in range(a.n):
        lang, cat, q = PROMPTS[i % len(PROMPTS)]
        payload = {
            "model": a.model,
            "temperature": 0,
            "max_tokens": a.max_tokens,
            "messages": [{"role": "user", "content": q}],
        }
        t0 = time.perf_counter()
        status, text, ctoks, err = None, "", 0, ""
        try:
            r = sess.post(endpoint, json=payload, timeout=a.timeout)
            status = r.status_code
            j = r.json()
            text = ((((j.get("choices") or [{}])[0]).get("message") or {}).get("content") or "").strip()
            ctoks = (j.get("usage") or {}).get("completion_tokens") or 0
            if status != 200:
                err = f"HTTP {status}"
        except Exception as e:  # noqa: BLE001
            err = f"{type(e).__name__}: {e}"
        el = time.perf_counter() - t0
        good = (status == 200) and len(text) > 0
        ok += good
        lat.append(el)
        if good:
            lat_ok.append(el)
        one = " ".join(text.split())
        rows.append([i + 1, lang, cat, status, "OK" if good else "ERR", f"{el:.3f}", ctoks, q[:60], one[:80], err])
        ans_f.write(json.dumps({"idx": i + 1, "lang": lang, "category": cat, "prompt": q, "answer": text, "ok": good,
                                "latency_s": round(el, 3), "completion_tokens": ctoks, "error": err}, ensure_ascii=False) + "\n")
        ans_f.flush()
        tag = f"{lang}·{cat}"
        tag += " " * max(0, 12 - sum(2 if ord(c) > 0x1100 else 1 for c in tag))   # 한글 2칸 기준 정렬
        print(f"[{i + 1:3d}/{a.n}] {'OK ' if good else 'ERR'} {el:6.3f}s  tok={ctoks:3d}  {tag} {one[:52]!r}{('  ' + err) if err else ''}", flush=True)

    # 응답시간 통계는 성공한 요청 기준 (즉시 실패한 요청이 p50/p95 를 왜곡하지 않도록) — 성공이 없으면 전체
    base = lat_ok if lat_ok else lat
    ls = sorted(base)
    p50, p95, mx, mean = statistics.median(base), percentile(ls, 95), ls[-1], statistics.mean(base)
    finished = dt.datetime.now()
    summary = (
        "\n=== TC3 soak result ===\n"
        f"requests      : {a.n}\n"
        f"success       : {ok}/{a.n} ({100.0 * ok / a.n:.1f}%)\n"
        f"latency p50   : {p50:.3f} s\n"
        f"latency p95   : {p95:.3f} s\n"
        f"latency max   : {mx:.3f} s\n"
        f"latency mean  : {mean:.3f} s\n"
        f"elapsed total : {sum(lat):.1f} s\n"
        f"finished      : {finished:%Y-%m-%d %H:%M:%S}\n"
    )
    print(summary, flush=True)

    ans_f.close()
    by_lang = {lg: sum(1 for r in rows if r[1] == lg and r[4] == "OK") for lg in ("KO", "EN")}
    print(f"by language   : KO {by_lang['KO']}/{sum(1 for r in rows if r[1] == 'KO')} OK, EN {by_lang['EN']}/{sum(1 for r in rows if r[1] == 'EN')} OK", flush=True)
    with open(a.out, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["idx", "lang", "category", "http_status", "result", "latency_s", "completion_tokens", "prompt_head", "response_head", "error"])
        w.writerows(rows)
    print(f"per-request log -> {a.out}", flush=True)
    print(f"answers (full) -> {ans_path}", flush=True)
    if a.summary_json:
        with open(a.summary_json, "w", encoding="utf-8") as f:
            json.dump({"n": a.n, "ok": ok, "success_pct": 100.0 * ok / a.n, "p50": p50, "p95": p95, "max": mx,
                       "mean": mean, "elapsed_s": sum(lat), "latency_basis": "success" if lat_ok else "all",
                       "started": f"{started:%Y-%m-%dT%H:%M:%S}", "finished": f"{finished:%Y-%m-%dT%H:%M:%S}"},
                      f, indent=2)
    sys.exit(0 if ok == a.n else 1)


if __name__ == "__main__":
    main()
