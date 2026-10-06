"""Foundation host parsing for the standalone Mac library exporter."""

import ctypes
import functools


@functools.lru_cache(maxsize=1)
def _runtime():
    foundation = ctypes.CDLL("/System/Library/Frameworks/Foundation.framework/Foundation")
    library = ctypes.CDLL("/usr/lib/libobjc.A.dylib")
    library.objc_getClass.argtypes = [ctypes.c_char_p]
    library.objc_getClass.restype = ctypes.c_void_p
    library.sel_registerName.argtypes = [ctypes.c_char_p]
    library.sel_registerName.restype = ctypes.c_void_p
    signature = (ctypes.c_void_p, ctypes.c_void_p)
    send = ctypes.CFUNCTYPE(ctypes.c_void_p, *signature)(("objc_msgSend", library))
    argument = ctypes.CFUNCTYPE(ctypes.c_void_p, *signature, ctypes.c_void_p)(("objc_msgSend", library))
    string = ctypes.CFUNCTYPE(ctypes.c_void_p, *signature, ctypes.c_char_p)(("objc_msgSend", library))
    utf8 = ctypes.CFUNCTYPE(ctypes.c_char_p, *signature)(("objc_msgSend", library))
    number = ctypes.CFUNCTYPE(ctypes.c_longlong, *signature)(("objc_msgSend", library))
    responds = ctypes.CFUNCTYPE(ctypes.c_bool, *signature, ctypes.c_void_p)(("objc_msgSend", library))
    drain = ctypes.CFUNCTYPE(None, *signature)(("objc_msgSend", library))
    return foundation, library, send, argument, string, utf8, number, responds, drain


def _host(url):
    _, library, send, argument, string, utf8, number, responds, drain = _runtime()
    selector = lambda name: library.sel_registerName(name.encode())
    pool = send(send(library.objc_getClass(b"NSAutoreleasePool"), selector("alloc")), selector("init"))
    try:
        text = string(library.objc_getClass(b"NSString"), selector("stringWithUTF8String:"), url.encode())
        components = argument(library.objc_getClass(b"NSURLComponents"), selector("componentsWithString:"), text)
        if not components:
            return None
        if not responds(components, selector("respondsToSelector:"), selector("encodedHost")):
            raise RuntimeError("Foundation encodedHost requires macOS 13 or newer")
        def value(name):
            pointer = send(components, selector(name))
            return utf8(pointer, selector("UTF8String")).decode() if pointer else None
        port = send(components, selector("port"))
        if ((value("scheme") or "").lower() != "https"
                or send(components, selector("user")) or send(components, selector("password"))
                or (port and number(port, selector("longLongValue")) != 443)):
            return None
        decoded, encoded = value("host"), value("encodedHost")
        return (decoded if "%" in encoded else encoded).lower() if decoded and encoded else None
    finally:
        drain(pool, selector("drain"))


@functools.lru_cache(maxsize=256)
def _cached_host(url):
    return _host(url)


def host(url):
    return _cached_host(url) if len(url) <= 4096 else _host(url)
