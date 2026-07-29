import SwiftUI

// 다크 "Color pill" 팔레트 (Claude Design 02안 hex 그대로).
enum Palette {
  static let bg = Color(hex: 0x16161A)
  static let divider = Color(hex: 0x232329)
  static let textPrimary = Color(hex: 0xECECF0)
  static let textSecondary = Color(hex: 0x76767E)
  static let priceMono = Color(hex: 0x7E7E88)
  static let manageLabel = Color(hex: 0xDCDCE2)
  static let time = Color(hex: 0x6F6F78)

  // 등락/손익 색 — 토스증권 규약: 상승·수익 빨강, 하락·손실 파랑.
  static let up = Color(hex: 0xF04452)
  static let down = Color(hex: 0x3182F6)
  static let neutral = Color(hex: 0x9A9AA3)
  static let upPill = Color(hex: 0xF04452, alpha: 0.14)
  static let downPill = Color(hex: 0x3182F6, alpha: 0.14)
  static let neutralPill = Color(hex: 0xFFFFFF, alpha: 0.08)

  // 인증 상태 색 — 등락과 무관한 성공/실패 의미(초록 OK / 소프트 레드 실패).
  static let success = Color(hex: 0x34D399)
  static let error = Color(hex: 0xF87171)

  static let indigo = Color(hex: 0xA5B4FC)
  static let indigoBG = Color(hex: 0x818CF8, alpha: 0.15)
  static let amber = Color(hex: 0xFBBF24)
  static let amberBG = Color(hex: 0xFBBF24, alpha: 0.14)
  static let manageTint = Color(hex: 0x9A9AA3)
  static let manageBG = Color(hex: 0xFFFFFF, alpha: 0.07)

  static let addBtn = Color(hex: 0x4F46E5)
  static let fieldBG = Color(hex: 0x0D0D10)
  static let fieldBorder = Color(hex: 0x2B2B31)
  static let deleteBG = Color(hex: 0xFFFFFF, alpha: 0.08)
  static let footerText = Color(hex: 0xCFCFD6)
  static let footerBtnBG = Color(hex: 0xFFFFFF, alpha: 0.06)
  static let quit = Color(hex: 0xF0A0A0)

  static let dropHi = Color(hex: 0x818CF8, alpha: 0.16)  // 드롭 타깃 슬롯 하이라이트
  static let dragLift = Color(hex: 0x26262E)  // 들어올린 행(떠 있는 카드) 배경
  static let rowHover = Color(hex: 0xFFFFFF, alpha: 0.05)  // 행 hover 배경
  static let handleHover = Color(hex: 0xFFFFFF, alpha: 0.07)  // 드래그 핸들 스트립 hover
  static let tooltipBG = Color(hex: 0x2E2E38)  // 미국 종목 hover 커스텀 툴팁 배경
}

extension Color {
  fileprivate init(hex: UInt32, alpha: Double = 1) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
      opacity: alpha)
  }
}
