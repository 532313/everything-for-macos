import Foundation

/// Bit flags stored in `FSEntry.flags`.
enum EntryFlag {
    static let isDir: UInt8 = 1 << 0
    static let isSymlink: UInt8 = 1 << 1
    static let isHidden: UInt8 = 1 << 2
    static let isPackage: UInt8 = 1 << 3
    static let isAlias: UInt8 = 1 << 4
    static let isDeleted: UInt8 = 1 << 5
    static let isExecutable: UInt8 = 1 << 6
}

/// One indexed filesystem object.
///
/// The record is deliberately tiny (32 bytes) and pointer free: all variable
/// length data lives in a single contiguous UTF-8 byte buffer (`FileIndex.pathBuf`)
/// so that a search over millions of rows is a linear, cache friendly scan.
struct FSEntry {
    /// Byte offset of the full path inside `FileIndex.pathBuf`.
    var pathOff: UInt32 = 0
    /// Byte length of the full path (no trailing NUL, no trailing slash).
    var pathLen: UInt32 = 0
    /// Byte length of the last path component (the file name).
    var nameLen: UInt16 = 0
    var flags: UInt8 = 0
    var pad: UInt8 = 0
    /// `st_size`
    var size: Int64 = 0
    /// Modification time, seconds since epoch (clamped to Int32 range).
    var mtime: Int32 = 0
    /// Creation (birth) time, seconds since epoch.
    var btime: Int32 = 0

    @inline(__always) var isDir: Bool { flags & EntryFlag.isDir != 0 }
    @inline(__always) var isFile: Bool { flags & EntryFlag.isDir == 0 }
    @inline(__always) var isHidden: Bool { flags & EntryFlag.isHidden != 0 }
    @inline(__always) var isPackage: Bool { flags & EntryFlag.isPackage != 0 }
    @inline(__always) var isSymlink: Bool { flags & EntryFlag.isSymlink != 0 }
    @inline(__always) var isDeleted: Bool { flags & EntryFlag.isDeleted != 0 }

    /// Byte offset of the file name inside `FileIndex.pathBuf`.
    @inline(__always) var nameOff: UInt32 { pathOff &+ pathLen &- UInt32(nameLen) }
}

/// Paths that the app knows to be opaque bundles: shown as a single object,
/// like Finder does, but still marked as a directory internally.
enum BundleExtensions {
    static let all: Set<String> = [
        "app", "bundle", "framework", "kext", "plugin", "prefpane", "qlgenerator",
        "saver", "mdimporter", "xpc", "appex", "lproj", "nib", "storyboardc",
        "xcassets", "playground", "scptd", "wkwebplugin", "webplugin", "docset",
        "rtfd", "pkg", "mpkg", "photoslibrary", "photolibrary", "imovielibrary",
        "tvlibrary", "theater", "musiclibrary", "aplibrary", "fcpbundle", "logicx",
        "band", "sparsebundle", "xcodeproj", "xcworkspace", "dSYM", "crash",
        "download", "pbproj", "rtf", "fs", "mlmodelc", "spriteatlas", "icon",
        "lpdf", "cannedsearch", "printer", "service", "workflow", "action",
        "keychain", "networkconnect", "vst", "component", "driver", "wdgt"
    ]
}

/// Kinds used for All / filter dropdowns (mirrors Everything's Filters menu).
enum FilterKind: String, CaseIterable, Identifiable {
    case all = "All"
    case audio = "Audio"
    case compressed = "Compressed"
    case document = "Document"
    case executable = "Executable"
    case folder = "Folder"
    case picture = "Picture"
    case video = "Video"
    case source = "Source code"

    var id: String { rawValue }

    /// Lowercase token accepted by `type:` in the search box.
    var keyword: String {
        switch self {
        case .all: return "all"
        case .audio: return "audio"
        case .compressed: return "compressed"
        case .document: return "document"
        case .executable: return "executable"
        case .folder: return "folder"
        case .picture: return "picture"
        case .video: return "video"
        case .source: return "source"
        }
    }

    /// Extra query fragment injected when this filter is selected.
    var queryFragment: String? {
        switch self {
        case .all: return nil
        case .folder: return "folder:"
        case .audio:
            return "ext:mp3;wav;aif;aiff;m4a;m4b;aac;flac;ogg;oga;opus;ape;wma;mid;midi;caf;au;aifc;amr"
        case .compressed:
            return "ext:zip;rar;7z;gz;bz2;xz;tar;tgz;tbz;tbz2;txz;z;lz;lzma;lzo;zst;cab;iso;dmg;jar;war;apk;ipa;xip;sit;sitx;sea;hqx;cpio;arj;lha;ace;pkg"
        case .document:
            return "ext:txt;rtf;rtfd;doc;docx;docm;dot;dotx;xls;xlsx;xlsm;ppt;pptx;pptm;pdf;pages;numbers;key;odt;ods;odp;epub;mobi;azw;azw3;djvu;tex;md;markdown;csv;tsv;json;xml;yaml;yml;html;htm;log;ini;cfg;conf;plist;strings;nfo;chm;wpd;wps;abw;xps;oxps"
        case .executable:
            return "ext:app;command;sh;bash;zsh;csh;ksh;fish;py;pl;rb;php;js;ts;jxa;jar;run;bin;exe;com;bat;cmd;msi;dll;so;dylib;a;o;ko;kext;xpc;appex;out;elf;wasm"
        case .picture:
            return "ext:jpg;jpeg;jpe;jfif;png;gif;bmp;tif;tiff;tga;webp;heic;heif;avif;ico;icns;raw;cr2;cr3;nef;arw;dng;orf;rw2;pef;srw;raf;3fr;x3f;psd;psb;ai;svg;eps;ps;jp2;j2k;pbm;pgm;ppm;xbm;xpm;dds;exr;hdr;pic;pct"
        case .video:
            return "ext:mp4;m4v;mov;avi;mkv;wmv;flv;f4v;webm;mpg;mpeg;mpe;m2v;m2ts;mts;vob;ogv;ogm;rm;rmvb;asf;3gp;3g2;divx;xvid;dv;mxf;roq;y4m;bik;swf;vtt;srt;ass;sub"
        case .source:
            return "ext:swift;m;mm;h;hpp;c;cc;cpp;cxx;hxx;cs;java;kt;kts;go;rs;py;pyw;rb;php;js;jsx;ts;tsx;vue;svelte;lua;pl;pm;r;jl;scala;clj;cljs;hs;erl;ex;exs;ml;fs;fsx;vb;pas;d;nim;zig;v;sv;vhd;asm;s;sql;sh;bash;zsh;fish;ps1;bat;cmd;makefile;cmake;gradle;toml;ini;cfg;yaml;yml;json;xml;html;css;scss;sass;less;md;rst;tex"
        }
    }
}
