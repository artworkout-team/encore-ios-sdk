//
//  SDUIFallbackConfig.swift
//  Encore
//
//  Embedded floor layouts for server-driven UI, one per use case.
//  Rung 3 of the availability ladder: what renders when nothing is known.
//

import Foundation

/// Per-use-case embedded floors.
///
/// Every use case ships its own floor, so a use case can never render
/// another's. Integrators wire `show()` to explicit UI ("Claim your reward"),
/// where a silent decline is a broken button.
enum SDUIFallbackConfig {

    /// The floor layout JSON for `useCase`. Each is use-case-appropriate;
    /// non-IAP use cases carry zero IAP triggers (test-pinned).
    static func json(for useCase: UseCase) -> String {
        switch useCase {
        case .reduceChurn: offerSheetJSON
        case .rewardUsers: rewardCelebrationJSON
        }
    }

    /// Parses the presentation style from the embedded JSON config
    static var presentationStyle: SDUIPresentationStyle {
        guard let data = offerSheetJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let styleString = json["presentationStyle"] as? String,
              let style = SDUIPresentationStyle(rawValue: styleString) else {
            return .default
        }
        return style
    }
    
    // MARK: - Floors

    // Floors live as literals, not bundle resources, on purpose: the SDK also
    // ships as a plain xcframework (xcode/Encore.xcodeproj archive, no
    // Bundle.module) and as CocoaPods source (podspec picks up *.swift only),
    // so a resource file would silently vanish from two of the three
    // distributions, and the floor is the one layout that must never be
    // missing at runtime.

    /// The churn-intervention floor: the shared sheet scaffold with the
    /// trial-pitch title block. Production fallback, always available.
    static let offerSheetJSON = sheetJSON(titleChildren: paywallTitleChildren)

    /// The post-action-reward floor: the same scaffold with the title block
    /// swapped for the placement call's headline and subheadline. Zero IAP
    /// triggers: this surface thanks the user, it never sells.
    ///
    /// `initialValues` defaults the copy tokens to empty so a floor render
    /// with no copy anywhere never shows a literal `${...}`; template
    /// variables (dashboard copy, placement overrides) resolve first and win.
    static let rewardCelebrationJSON = sheetJSON(
        initialValues: ["rewardHeadline": "", "rewardSubheadline": ""],
        titleChildren: rewardTitleChildren
    )

    // MARK: - Shared Scaffold

    private static let paywallTitleChildren = """
                                                    {
                                                        "text": {
                                                            "text": "",
                                                            "font": {
                                                                "size": 24,
                                                                "weight": "semibold"
                                                            },
                                                            "segments": [
                                                                {
                                                                    "text": "Get ${trialValue} ${trialUnit} of ${appName}",
                                                                    "color": {
                                                                        "semantic": "label"
                                                                    }
                                                                },
                                                                {
                                                                    "text": " for free",
                                                                    "color": {
                                                                        "hex": "#16BD25"
                                                                    }
                                                                }
                                                            ],
                                                            "style": {
                                                                "padding": {
                                                                    "trailing": 90
                                                                }
                                                            }
                                                        }
                                                    },
                                                    {
                                                        "text": {
                                                            "text": "Claim an exclusive deal and get ${appName} for free",
                                                            "font": {
                                                                "size": 17,
                                                                "weight": "regular"
                                                            },
                                                            "color": {
                                                                "semantic": "secondaryLabel"
                                                            },
                                                            "lineSpacing": 2
                                                        }
                                                    }
"""

    private static let rewardTitleChildren = """
                                                    {
                                                        "text": {
                                                            "text": "${rewardHeadline}",
                                                            "font": {
                                                                "size": 24,
                                                                "weight": "semibold"
                                                            },
                                                            "color": {
                                                                "semantic": "label"
                                                            },
                                                            "style": {
                                                                "padding": {
                                                                    "trailing": 90
                                                                }
                                                            }
                                                        }
                                                    },
                                                    {
                                                        "text": {
                                                            "text": "${rewardSubheadline}",
                                                            "font": {
                                                                "size": 17,
                                                                "weight": "regular"
                                                            },
                                                            "color": {
                                                                "semantic": "secondaryLabel"
                                                            },
                                                            "lineSpacing": 2
                                                        }
                                                    }
"""

    /// Renders the shared sheet scaffold: background, drag handle, close
    /// button, the given title block, the claim carousel, and the page
    /// indicator. Every floor is this scaffold with a different title block,
    /// byte-mirrored on Android.
    private static func sheetJSON(initialValues: [String: String] = [:], titleChildren: String) -> String {
        let seed = initialValues.isEmpty ? "" : "\n    \"initialValues\": {"
            + initialValues.keys.sorted()
                .map { "\n        \"\($0)\": \"\(initialValues[$0] ?? "")\"" }
                .joined(separator: ",")
            + "\n    },"
        return """
{
    "version": "1.0.0",
    "presentationDetents": [
        0.54,
        0.95
    ],
    "cornerRadius": null,
    "showDragIndicator": false,\(seed)
    "root": {
        "zStack": {
            "alignment": "top",
            "children": [
                {
                    "shape": {
                        "type": "rectangle",
                        "fillColor": {
                            "semantic": "systemGroupedBackground"
                        },
                        "style": {
                            "ignoresSafeArea": true
                        }
                    }
                },
                {
                    "vStack": {
                        "spacing": 0,
                        "children": [
                            {
                                "vStack": {
                                    "spacing": 0,
                                    "children": [
                                        {
                                            "shape": {
                                                "type": "roundedRectangle",
                                                "cornerRadius": 2.5,
                                                "fillColor": {
                                                    "semantic": "separator"
                                                },
                                                "style": {
                                                    "padding": {
                                                        "top": 8
                                                    },
                                                    "frame": {
                                                        "width": 46,
                                                        "height": 5
                                                    }
                                                }
                                            }
                                        },
                                        {
                                            "hStack": {
                                                "children": [
                                                    {
                                                        "spacer": {}
                                                    },
                                                    {
                                                        "button": {
                                                            "content": {
                                                                "systemImage": {
                                                                    "systemName": "xmark",
                                                                    "font": {
                                                                        "size": 15,
                                                                        "weight": "semibold"
                                                                    },
                                                                    "color": {
                                                                        "semantic": "tertiaryLabel"
                                                                    }
                                                                }
                                                            },
                                                            "action": "close",
                                                            "style": {
                                                                "padding": {
                                                                    "top": 20,
                                                                    "trailing": 20
                                                                }
                                                            }
                                                        }
                                                    }
                                                ]
                                            }
                                        },
                                        {
                                            "vStack": {
                                                "spacing": 8,
                                                "alignment": "leading",
                                                "children": [
\(titleChildren)
                                                ],
                                                "style": {
                                                    "padding": {
                                                        "top": 2,
                                                        "leading": 20,
                                                        "trailing": 40
                                                    },
                                                    "frame": {
                                                        "maxWidth": "infinity",
                                                        "alignment": "leading"
                                                    }
                                                }
                                            }
                                        }
                                    ]
                                }
                            },
                            {
                                "scrollView": {
                                    "axis": "horizontal",
                                    "showsIndicators": false,
                                    "scrollTargetBehavior": "viewAligned",
                                    "contentMargins": {
                                        "horizontal": 20
                                    },
                                    "content": {
                                        "hStack": {
                                            "spacing": 12,
                                            "children": [
                                                {
                                                    "forEach": {
                                                        "dataSource": "offers",
                                                        "itemTemplate": {
                                                            "vStack": {
                                                                "spacing": 0,
                                                                "children": [
                                                                    {
                                                                        "asyncImage": {
                                                                            "urlBinding": "offerPrimaryCreative",
                                                                            "contentMode": "fit",
                                                                            "aspectRatio": 2.369,
                                                                            "placeholderColor": {
                                                                                "semantic": "tertiarySystemFill"
                                                                            },
                                                                            "style": {
                                                                                "frame": {
                                                                                    "maxWidth": "infinity"
                                                                                },
                                                                                "clipped": true,
                                                                                "cornerRadius": 16
                                                                            }
                                                                        }
                                                                    },
                                                                    {
                                                                        "hStack": {
                                                                            "spacing": 12,
                                                                            "alignment": "center",
                                                                            "children": [
                                                                                {
                                                                                    "asyncImage": {
                                                                                        "urlBinding": "offerLogoImage",
                                                                                        "contentMode": "fit",
                                                                                        "placeholderColor": {
                                                                                            "semantic": "tertiarySystemFill"
                                                                                        },
                                                                                        "style": {
                                                                                            "frame": {
                                                                                                "width": 42,
                                                                                                "height": 42
                                                                                            },
                                                                                            "cornerRadius": 8,
                                                                                            "clipShape": {
                                                                                                "rectangle": {
                                                                                                    "cornerRadius": 8
                                                                                                }
                                                                                            }
                                                                                        }
                                                                                    }
                                                                                },
                                                                                {
                                                                                    "vStack": {
                                                                                        "spacing": 2,
                                                                                        "alignment": "leading",
                                                                                        "children": [
                                                                                            {
                                                                                                "text": {
                                                                                                    "text": "",
                                                                                                    "textBinding": "offerAdvertiserName",
                                                                                                    "font": {
                                                                                                        "size": 16,
                                                                                                        "weight": "semibold"
                                                                                                    },
                                                                                                    "color": {
                                                                                                        "semantic": "label"
                                                                                                    },
                                                                                                    "lineLimit": 1
                                                                                                }
                                                                                            },
                                                                                            {
                                                                                                "text": {
                                                                                                    "text": "",
                                                                                                    "textBinding": "offerDescription",
                                                                                                    "font": {
                                                                                                        "size": 14,
                                                                                                        "weight": "regular"
                                                                                                    },
                                                                                                    "color": {
                                                                                                        "semantic": "secondaryLabel"
                                                                                                    },
                                                                                                    "lineLimit": 1,
                                                                                                    "multilineAlignment": "leading"
                                                                                                }
                                                                                            }
                                                                                        ],
                                                                                        "style": {
                                                                                            "frame": {
                                                                                                "maxWidth": "infinity",
                                                                                                "alignment": "leading"
                                                                                            }
                                                                                        }
                                                                                    }
                                                                                },
                                                                                {
                                                                                    "spacer": {
                                                                                        "minLength": 8
                                                                                    }
                                                                                },
                                                                                {
                                                                                    "button": {
                                                                                        "content": {
                                                                                            "text": {
                                                                                                "text": "Claim",
                                                                                                "textBinding": "offerCtaText",
                                                                                                "font": {
                                                                                                    "size": 14,
                                                                                                    "weight": "semibold"
                                                                                                },
                                                                                                "color": {
                                                                                                    "hex": "#FFFFFF"
                                                                                                },
                                                                                                "lineHeight": 1.2
                                                                                            }
                                                                                        },
                                                                                        "action": "claimOffer",
                                                                                        "style": {
                                                                                            "padding": {
                                                                                                "top": 8.5,
                                                                                                "leading": 19.5,
                                                                                                "bottom": 8.5,
                                                                                                "trailing": 19.5
                                                                                            },
                                                                                            "frame": {
                                                                                                "minWidth": 78
                                                                                            },
                                                                                            "cornerRadius": 9999,
                                                                                            "backgroundColor": {
                                                                                                "hex": "#6743F5"
                                                                                            }
                                                                                        }
                                                                                    }
                                                                                }
                                                                            ],
                                                                            "style": {
                                                                                "padding": {
                                                                                    "top": 14,
                                                                                    "leading": 16,
                                                                                    "bottom": 14,
                                                                                    "trailing": 16
                                                                                },
                                                                                "backgroundColor": {
                                                                                    "semantic": "secondarySystemGroupedBackground"
                                                                                }
                                                                            }
                                                                        }
                                                                    }
                                                                ],
                                                                "style": {
                                                                    "containerRelativeFrame": {
                                                                        "axis": "horizontal"
                                                                    },
                                                                    "cornerRadius": 16,
                                                                    "backgroundColor": {
                                                                        "semantic": "secondarySystemGroupedBackground"
                                                                    },
                                                                    "shadow": {
                                                                        "color": {
                                                                            "semantic": "label"
                                                                        },
                                                                        "radius": 4,
                                                                        "x": 0,
                                                                        "y": 0
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            ],
                                            "style": {
                                                "scrollTargetLayout": true
                                            }
                                        }
                                    },
                                    "style": {
                                        "padding": {
                                            "top": 20
                                        }
                                    }
                                }
                            },
                            {
                                "conditional": {
                                    "condition": {
                                        "hasMultipleOffers": {}
                                    },
                                    "ifTrue": {
                                        "group": {
                                            "content": {
                                                "compactPageIndicator": {}
                                            },
                                            "style": {
                                                "padding": {
                                                    "top": 15
                                                }
                                            }
                                        }
                                    }
                                }
                            },
                            {
                                "spacer": {}
                            }
                        ],
                        "style": {
                            "frame": {
                                "maxWidth": "infinity",
                                "maxHeight": "infinity",
                                "alignment": "top"
                            },
                            "ignoresSafeArea": true
                        }
                    }
                },
                {
                    "empty": {}
                }
            ]
        }
    }
}
"""
    }
}
