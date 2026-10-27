// Run with vphoned script.eval. Read-only: loads frameworks in the disposable
// script session; does not alter preferences, register a display, or swap panels.
(() => {
    const result = { displays: [], errors: [] };
    for (const name of ["CoreMotion", "SpringBoardServices", "FrontBoardServices"]) {
        const root = name === "CoreMotion" ? "Frameworks" : "PrivateFrameworks";
        try {
            const bundle = ObjC.classes.NSBundle.bundleWithPath_(
                `/System/Library/${root}/${name}.framework`
            );
            if (!bundle || !bundle.load()) result.errors.push(`Could not load ${name}`);
        } catch (error) {
            result.errors.push(String(error));
        }
    }
    try {
        const displays = ObjC.classes.CADisplay.displays();
        for (let index = 0; index < displays.count(); index++) {
            const display = displays.objectAtIndex_(index);
            result.displays.push({
                name: display.name(),
                deviceName: display.deviceName(),
                displayId: display.displayId(),
                displayType: display.displayType(),
                external: display.isExternal(),
                currentMode: String(display.currentMode()),
                availableModes: String(display.availableModes()),
                nativeOrientation: display.nativeOrientation(),
                currentOrientation: display.currentOrientation(),
                hardwareUUID: String(display.UUID()),
            });
        }
    } catch (error) {
        result.errors.push(String(error));
    }
    // The disposable process's UIKit initial context can differ from the live
    // compositor. Record both, without treating either as SpringBoard's state.
    try {
        const display = ObjC.classes.CADisplay.mainDisplay();
        result.rawDisplayConfiguration = String(ObjC.classes.FBSDisplayConfiguration
            .alloc().initWithCADisplay_(display));
        const screen = ObjC.classes.UIScreen.mainScreen();
        result.probeUIKitScreen = String(screen);
        result.probeUIKitConfiguration = String(screen.displayConfiguration());
    } catch (error) {
        result.errors.push(String(error));
    }
    try {
        result.magicPoseAvailable = ObjC.classes.CMMagicPoseManager.isAvailable();
        result.hingeStates = [0, 1, 2, 3, 4, 5].map(value => ({
            value,
            name: ObjC.classes.CMMagicPoseEvent.stringForHingeState_(value),
        }));
    } catch (error) {
        result.errors.push(String(error));
    }
    try {
        result.swapServicePresent = ObjC.classes.SBSDisplayToolService
            .instancesRespondToSelector_("swapDisplayWithSettings:completionHandler:");
    } catch (error) {
        result.errors.push(String(error));
    }
    // Service availability is not a capability verdict. A successful swap
    // callback does not prove that an inner framebuffer exists or is rendered.
    return result;
})();
