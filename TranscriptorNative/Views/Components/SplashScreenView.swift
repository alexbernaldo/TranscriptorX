import SwiftUI

// MARK: - Splash Screen View (Legacy)
/// This file is kept for reference but is no longer used.
/// The splash functionality is now integrated into MasterView.swift
/// which uses matchedGeometryEffect for seamless logo transition.
///
/// See: Views/Main/MasterView.swift

// The MasterView contains both splash and home states in a single view,
// using the following key components:
// - isAppReady: Boolean controlling splash vs home phase
// - matchedGeometryEffect: Makes logo transition seamlessly
// - Spring physics: Natural, weighted animation feel
// - Staggered entrance: Elements appear with delays for "pulling" effect

#if DEBUG
struct SplashScreenView_Previews: PreviewProvider {
    static var previews: some View {
        Text("El splash ahora está integrado en MasterView")
            .padding()
            .background(Color.bgPrimary)
    }
}
#endif
