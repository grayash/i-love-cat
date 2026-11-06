# i-love-cat · 고양이 성분표 분석기

사료·간식 성분표를 찍으면 고양이에게 좋은 성분과 피해야 할 성분을 알려주는 모바일 웹.

## 배포
GitHub Pages: Settings → Pages → Branch `main` / root → 주소 `https://grayash.github.io/i-love-cat/`

## 게시판·의견 받기 (Supabase)
1. supabase.com 무료 프로젝트 생성
2. SQL Editor에 `supabase_setup.sql` 전체를 붙여넣고 Run
3. Project Settings → API 의 Project URL / anon public key를 `index.html` 상단 `CONFIG.SUPABASE_URL`, `CONFIG.SUPABASE_ANON_KEY`에 입력

## 방문·이용 통계 (Firebase Analytics)
1. console.firebase.google.com 에서 프로젝트 `i-love-cat` 생성 (Google Analytics 사용 켜기)
2. 프로젝트 설정 → 내 앱 → 웹 앱(</>) 추가 → `firebaseConfig` 확인
3. 값을 `index.html` 상단 `CONFIG.FIREBASE`에 입력 (apiKey, authDomain, projectId, storageBucket, messagingSenderId, appId, measurementId)
4. 콘솔 Analytics → Realtime 에서 확인. 수집 이벤트: screen_view, scan_start, analyze, post_submit, rate_submit, feedback_submit, share, ref_open
