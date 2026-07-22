#!/usr/bin/env swift
// 앱 아이콘 "02 Trend line" 렌더러.
// Claude Design 프로젝트(토스 주식 맥북 상태바 · "앱 아이콘.dc.html")의 02 · Trend line 시안을
// CoreGraphics 로 그려 macOS .iconset PNG 시퀀스를 생성한다. 이후 iconutil 로 .icns 조립.
//
// 좌표계: 디자인 시안 viewBox(0..100, y-down)를 그대로 쓰기 위해 컨텍스트를 한 번 뒤집는다.
// 타일: macOS 아이콘 그리드에 맞춰 1024 캔버스에 824 스퀘어클(여백 100, 코너 185) — 시안 코너비 49/220≈0.223.
// 사용법: swift make-icon.swift [출력_iconset_경로]   (기본 AppIcon.iconset)

import Foundation
import CoreGraphics
import ImageIO

// ── 디자인 상수 (앱 아이콘.dc.html · 02 Trend line) ──
let UP: [CGFloat] = [52/255, 211/255, 153/255, 1]        // #34d399 상승 초록
// 인디고 브랜드 그라데이션 linear-gradient(160deg, #4f46e5 0%, #312e81 60%, #1e1b4b 100%)
let stop0: [CGFloat] = [79/255, 70/255, 229/255, 1]      // #4f46e5
let stop1: [CGFloat] = [49/255, 46/255, 129/255, 1]      // #312e81
let stop2: [CGFloat] = [30/255, 27/255, 75/255, 1]       // #1e1b4b

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ c: [CGFloat]) -> CGColor { CGColor(colorSpace: cs, components: c)! }

// 1024 논리 공간(캔버스). 타일 = 여백 100, 변 824.
let CANVAS: CGFloat = 1024
let INSET: CGFloat = 100
let TILE: CGFloat = CANVAS - INSET * 2      // 824
let RADIUS: CGFloat = 185                    // 824 * 0.2246 ≈ macOS 스퀘어클
let tileRect = CGRect(x: INSET, y: INSET, width: TILE, height: TILE)

// 드롭섀도우: 위에서 오는 광원 → 스퀘어클 아래 은은한 그림자 (여백 100 안에 들어가야 잘리지 않음)
let SHADOW_BLUR: CGFloat = 36
let SHADOW_DY: CGFloat = 14                   // y-down 논리공간: 양수 = 화면 아래
let SHADOW_ALPHA: CGFloat = 0.32

// 시안 0..100 좌표 → 타일 내부 좌표 매핑
func T(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: INSET + x / 100 * TILE, y: INSET + y / 100 * TILE)
}
let ART_SCALE = TILE / 100                   // 선 굵기 등 스칼라 스케일 (8.24)

// 160deg 그라데이션 방향 벡터(화면 y-down): (sin160, -cos160)
let ang = 160.0 * Double.pi / 180
let dir = CGPoint(x: CGFloat(sin(ang)), y: CGFloat(-cos(ang)))
let center = CGPoint(x: tileRect.midX, y: tileRect.midY)
let half = 0.5 * TILE * (abs(dir.x) + abs(dir.y))   // 정사각 대각 커버
let gradStart = CGPoint(x: center.x - half * dir.x, y: center.y - half * dir.y)
let gradEnd = CGPoint(x: center.x + half * dir.x, y: center.y + half * dir.y)
let gradient = CGGradient(colorsSpace: cs,
                          colors: [color(stop0), color(stop1), color(stop2)] as CFArray,
                          locations: [0, 0.6, 1])!

func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // 투명 배경 + y-down 1024 논리 공간
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: 1, y: -1)
    let k = CGFloat(px) / CANVAS
    ctx.scaleBy(x: k, y: k)

    let tilePath = CGPath(roundedRect: tileRect, cornerWidth: RADIUS, cornerHeight: RADIUS, transform: nil)

    // 드롭섀도우: 불투명 실루엣을 먼저 깔아 그림자만 생성 (위 그라데이션이 실루엣을 완전히 덮음)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: SHADOW_DY), blur: SHADOW_BLUR,
                  color: color([0, 0, 0, SHADOW_ALPHA]))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(stop2))
    ctx.fillPath()
    ctx.restoreGState()

    // 타일: 인디고 그라데이션 (스퀘어클 클립)
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    ctx.drawLinearGradient(gradient, start: gradStart, end: gradEnd,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // 라인 아래 면적 채움 (초록 opacity .14)
    let areaPts = [T(16,66), T(34,54), T(50,60), T(66,36), T(84,26), T(84,84), T(16,84)]
    let area = CGMutablePath()
    area.addLines(between: areaPts); area.closeSubpath()
    ctx.addPath(area)
    ctx.setFillColor(color([UP[0], UP[1], UP[2], 0.14]))
    ctx.fillPath()

    // 상승 추세선 (초록, round cap/join)
    let linePts = [T(16,66), T(34,54), T(50,60), T(66,36), T(84,26)]
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setStrokeColor(color(UP))
    ctx.setLineWidth(7 * ART_SCALE)
    ctx.addLines(between: linePts)
    ctx.strokePath()

    // 끝점 도트 (흰 원 + 초록 원)
    let dot = T(84,26)
    func circle(_ r: CGFloat, _ c: CGColor) {
        ctx.setFillColor(c)
        ctx.fillEllipse(in: CGRect(x: dot.x - r, y: dot.y - r, width: r*2, height: r*2))
    }
    circle(7 * ART_SCALE, color([1,1,1,1]))
    circle(3.4 * ART_SCALE, color(UP))

    ctx.restoreGState()
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("PNG 쓰기 실패: \(path)") }
}

// ── iconset 조립 ──
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// (픽셀 크기, [파일명...]) — 32/256/512 는 두 이름으로 공유
let plan: [(Int, [String])] = [
    (16,  ["icon_16x16.png"]),
    (32,  ["icon_16x16@2x.png", "icon_32x32.png"]),
    (64,  ["icon_32x32@2x.png"]),
    (128, ["icon_128x128.png"]),
    (256, ["icon_128x128@2x.png", "icon_256x256.png"]),
    (512, ["icon_256x256@2x.png", "icon_512x512.png"]),
    (1024,["icon_512x512@2x.png"]),
]
for (px, names) in plan {
    let img = render(px)
    for n in names { writePNG(img, "\(outDir)/\(n)") }
}
print("iconset 생성 완료: \(outDir)")
