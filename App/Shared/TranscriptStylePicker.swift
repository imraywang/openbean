// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// 转写上方的「干净 / 原文」切换：改的就是设置里的「去掉语气词」（复制、导出、笔记也跟着它）
struct TranscriptStylePicker: View {
    @Bindable var settings: Settings

    var body: some View {
        Picker("Transcript text", selection: $settings.cleanTranscripts) {
            Text("Clean").tag(true)
            Text("Original").tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Clean hides filler words, stutters and repeats. Original is the text as recognised.")
    }
}
