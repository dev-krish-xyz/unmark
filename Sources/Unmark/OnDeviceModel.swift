import Foundation
import UnmarkCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device language model (Apple Intelligence). Text never leaves the Mac, and the app
/// keeps its sandbox without any network entitlement.
@MainActor
enum OnDeviceModel {
    /// Nil when Reword can run; otherwise why not, phrased for the user.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return "This Mac doesn’t support Apple Intelligence."
                case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in System Settings to use Reword."
                case .modelNotReady: return "Apple Intelligence is still downloading. Try again later."
                @unknown default: return "Apple’s on-device model isn’t available right now."
                }
            }
        }
        return "Reword needs macOS 26 or later with Apple Intelligence."
        #else
        return "This build of Unmark doesn’t include Reword."
        #endif
    }

    static func make() -> (any RewriteModel)? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), unavailableReason == nil {
            return AppleRewriteModel()
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@MainActor
private final class AppleRewriteModel: RewriteModel {
    /// Rewriting text the user supplied is a content transformation, so the permissive
    /// guardrails apply: they still block generating harmful content, but don't refuse to
    /// rephrase text that merely mentions sensitive topics.
    private let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)

    func generate(_ request: GenerationRequest, onPartial: (String) -> Void) async throws -> String {
        // A fresh session per passage: no earlier passage or answer is in context.
        let session = LanguageModelSession(model: model, instructions: request.instructions)
        let stream = session.streamResponse(to: request.prompt, options: GenerationOptions(temperature: request.temperature))
        var latest = ""
        do {
            for try await snapshot in stream {
                latest = snapshot.content
                onPartial(latest)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.rewriteError(for: error)
        }
        return latest
    }

    private static func rewriteError(for error: any Error) -> RewriteError {
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal: return .declined
            case .unsupportedLanguageOrLocale: return .unsupportedLanguage
            case .rateLimited, .concurrentRequests: return .busy
            case .assetsUnavailable: return .unavailable("Apple Intelligence isn’t ready yet. Try again later.")
            default: break
            }
        }
        // Newer SDKs report some of these through other error types; match them by name.
        let description = String(reflecting: error)
        if description.contains("guardrail") || description.contains("refusal") { return .declined }
        if description.contains("unsupportedLanguage") { return .unsupportedLanguage }
        if description.contains("rateLimited") || description.contains("concurrentRequests") { return .busy }
        return .failed(error.localizedDescription)
    }
}
#endif
