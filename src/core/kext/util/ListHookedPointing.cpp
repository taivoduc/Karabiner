#include "ListHookedPointing.hpp"
#include "Core.hpp"
#include "Config.hpp"

namespace org_pqrs_KeyRemap4MacBook {
  namespace {
    ListHookedPointing listHookedPointing;
  }

  ListHookedPointing &
  ListHookedPointing::instance(void)
  {
    return listHookedPointing;
  }

  // ----------------------------------------------------------------------
  namespace {
    void
    hook_RelativePointerEventCallback(OSObject *target,
                                      int buttons,
                                      int dx,
                                      int dy,
                                      AbsoluteTime ts,
                                      OSObject *sender,
                                      void *refcon)
    {
      Params_RelativePointerEventCallback params = {
        target, buttons, dx, dy, ts, sender, refcon,
      };
      Core::remap_RelativePointerEventCallback(&params);
    }

    void
    hook_ScrollWheelEventCallback(OSObject * target,
                                  short deltaAxis1,
                                  short deltaAxis2,
                                  short deltaAxis3,
                                  IOFixed fixedDelta1,
                                  IOFixed fixedDelta2,
                                  IOFixed fixedDelta3,
                                  SInt32 pointDelta1,
                                  SInt32 pointDelta2,
                                  SInt32 pointDelta3,
                                  SInt32 options,
                                  AbsoluteTime ts,
                                  OSObject *sender,
                                  void *refcon)
    {
      Params_ScrollWheelEventCallback params = {
        target,
        deltaAxis1, deltaAxis2, deltaAxis3,
        fixedDelta1, fixedDelta2, fixedDelta3,
        pointDelta1, pointDelta2, pointDelta3,
        options, ts, sender, refcon,
      };
      Core::remap_ScrollWheelEventCallback(&params);
    }
  }

  HookedPointing::HookedPointing(void) :
    isAppleDriver(false),
    orig_relativePointerEventAction(NULL), orig_scrollWheelEventAction(NULL),
    orig_relativePointerEventTarget(NULL), orig_scrollWheelEventTarget(NULL)
  {
  }

  bool
  HookedPointing::initialize(IOHIDevice *_device)
  {
    const char *name = _device->getName();

    device = _device;
    IOLog("KeyRemap4MacBook HookedPointing::initialize name = %s, device = 0x%p\n", name, device);

    if (strcmp(name, "IOHIDPointing") == 0 ||
        strcmp(name, "AppleUSBGrIIITrackpad") == 0 ||
        strcmp(name, "AppleADBMouseType4") == 0) {
      isAppleDriver = true;
    } else {
      isAppleDriver = false;
    }

    return refresh();
  }

  bool
  HookedPointing::refresh(void)
  {
    if (! isAppleDriver && ! config.general_remap_thirdvendor_pointing) {
      return restoreEventAction();
    }
    return replaceEventAction();
  }

  bool
  HookedPointing::terminate(void)
  {
    bool result = restoreEventAction();
    device = NULL;
    return result;
  }

  bool
  HookedPointing::replaceEventAction(void)
  {
    if (! device) return false;

    IOHIPointing *pointing = OSDynamicCast(IOHIPointing, device);
    if (! pointing) return false;

    // ----------------------------------------
    {
      RelativePointerEventCallback callback = reinterpret_cast<RelativePointerEventCallback>(pointing->_relativePointerEventAction);

      if (callback != hook_RelativePointerEventCallback) {
        IOLog("KeyRemap4MacBook [refresh] RelativePointerEventAction (device = 0x%p)\n", device);

        orig_relativePointerEventAction = callback;
        orig_relativePointerEventTarget = pointing->_relativePointerEventTarget;

        pointing->_relativePointerEventAction = reinterpret_cast<RelativePointerEventAction>(hook_RelativePointerEventCallback);
      }
    }
    {
      ScrollWheelEventCallback callback = reinterpret_cast<ScrollWheelEventCallback>(pointing->_scrollWheelEventAction);

      if (callback != hook_ScrollWheelEventCallback) {
        IOLog("KeyRemap4MacBook [refresh] ScrollWheelEventAction (device = 0x%p)\n", device);

        orig_scrollWheelEventAction = callback;
        orig_scrollWheelEventTarget = pointing->_scrollWheelEventTarget;

        pointing->_scrollWheelEventAction = reinterpret_cast<ScrollWheelEventAction>(hook_ScrollWheelEventCallback);
      }
    }

    return true;
  }

  bool
  HookedPointing::restoreEventAction(void)
  {
    if (! device) return false;

    IOHIPointing *pointing = OSDynamicCast(IOHIPointing, device);
    if (! pointing) return false;

    // ----------------------------------------
    {
      RelativePointerEventCallback callback = reinterpret_cast<RelativePointerEventCallback>(pointing->_relativePointerEventAction);

      if (callback == hook_RelativePointerEventCallback) {
        pointing->_relativePointerEventAction = reinterpret_cast<RelativePointerEventAction>(orig_relativePointerEventAction);
      }
    }
    {
      ScrollWheelEventCallback callback = reinterpret_cast<ScrollWheelEventCallback>(pointing->_scrollWheelEventAction);

      if (callback == hook_ScrollWheelEventCallback) {
        pointing->_scrollWheelEventAction = reinterpret_cast<ScrollWheelEventAction>(orig_scrollWheelEventAction);
      }
    }

    return true;
  }
}
