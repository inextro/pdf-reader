# PaperMark

맥에서 논문 PDF를 읽으며 **마우스로 원하는 색의 형광펜**을 칠하는 작은 PDF 리더.
아이패드는 PDF Expert를 그대로 쓰고, 맥에서 빠진 기능만 채운다.

## 결정 사항

- **네이티브 macOS 앱(Swift + PDFKit)**: 아이패드는 PDF Expert가 맡으니 맥만 지원하면 된다.
  Xcode 없이 SwiftPM으로 빌드하고, 본인 맥 전용이라 개발자 계정이 필요 없다.
- **Google Drive 연동 = Drive 데스크톱 폴더 직접 사용**: `~/Library/CloudStorage/GoogleDrive-…/My Drive`의
  파일을 열고 그 자리에 저장한다. OAuth나 API 코드가 없다.
- **형광펜 = PDF 표준 `/Highlight` 주석**: 파일 안에 저장되고(`QuadPoints`, `/C`, 외형 스트림 `/AP`)
  PDF Expert와 미리보기에서 그대로 보인다. PDF Expert에서 칠한 형광펜도 이 앱에서 보이고 지울 수 있다.
  선택 하나는 페이지마다 주석 하나(줄마다 사각형 하나)로 만든다.
- **UI는 영어**: 개발 언어(`CFBundleDevelopmentRegion`)를 `en`으로 두어 열기 창 같은 시스템 UI도 영어로 나온다.
- **자동 저장**: 형광펜을 바꾸면 1.5초 뒤 원래 파일에 저장한다. 시스템 자동 저장(버전 보관)은
  Drive 볼륨에서 동작이 확실하지 않아 쓰지 않는다.
- **다른 기기에서 바뀐 파일**: 열어둔 상태에서 Drive가 새 버전을 받아오면, 아직 저장하지 않은 변경이
  없을 때 다시 읽는다.

## 사용법

| 동작 | 방법 |
|---|---|
| 칠하기 | 형광펜 모드(툴바 형광펜 버튼, `⇧⌘D`)가 켜져 있으면 드래그하는 즉시 칠한다. 꺼져 있으면 선택 후 `⌘D` |
| 색 고르기 | 툴바 동그라미 클릭. 색상 웰로 직접 고르고 `+`로 프리셋 추가. 동그라미 우클릭으로 프리셋 제거 |
| 지우기, 색 바꾸기 | 형광펜 위에서 우클릭 |
| 실행 취소 | `⌘Z` / `⇧⌘Z` |
| 검색 | `⌘F` 후 입력하고 Enter. 다시 Enter(또는 `⌘G`)는 다음 결과, `⇧Enter`(또는 `⇧⌘G`)는 이전 결과 |
| 확대, 축소 | `⌘=` / `⌘-` / `⌘0`(창에 맞추기) |

## 빌드

```sh
./scripts/build-app.sh            # build/PaperMark.app
./scripts/build-app.sh --install  # ~/Applications 에 설치
swift run pmcheck <출력폴더>      # 형광펜 저장·재로딩 검증 (샘플 PDF 생성)
```

PDF 파일의 "다음으로 열기"에서 PaperMark를 고를 수 있다.
