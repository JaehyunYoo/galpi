import AppKit

// Editable vector artwork, rendered at every macOS icon size.
func color(_ red:CGFloat,_ green:CGFloat,_ blue:CGFloat,_ alpha:CGFloat=1) -> NSColor {
    NSColor(srgbRed:red/255,green:green/255,blue:blue/255,alpha:alpha)
}
func bookmark(_ rect:NSRect,corner:CGFloat,notch:CGFloat) -> NSBezierPath {
    let path=NSBezierPath(),x=rect.minX,y=rect.minY,w=rect.width,h=rect.height,r=corner
    path.move(to:NSPoint(x:x,y:y))
    path.line(to:NSPoint(x:x,y:y+h-r))
    path.curve(to:NSPoint(x:x+r,y:y+h),controlPoint1:NSPoint(x:x,y:y+h-r*0.45),controlPoint2:NSPoint(x:x+r*0.45,y:y+h))
    path.line(to:NSPoint(x:x+w-r,y:y+h))
    path.curve(to:NSPoint(x:x+w,y:y+h-r),controlPoint1:NSPoint(x:x+w-r*0.45,y:y+h),controlPoint2:NSPoint(x:x+w,y:y+h-r*0.45))
    path.line(to:NSPoint(x:x+w,y:y))
    path.line(to:NSPoint(x:x+w/2,y:y+notch))
    path.close();return path
}
func drawIcon(_ pixels:Int) throws -> Data {
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    let context=NSGraphicsContext(bitmapImageRep:bitmap)!
    NSGraphicsContext.saveGraphicsState();defer{NSGraphicsContext.restoreGraphicsState()}
    NSGraphicsContext.current=context
    context.imageInterpolation = .high
    context.cgContext.scaleBy(x:CGFloat(pixels)/1024,y:CGFloat(pixels)/1024)
    let tile=NSBezierPath(roundedRect:NSRect(x:54,y:54,width:916,height:916),xRadius:208,yRadius:208)
    NSGraphicsContext.saveGraphicsState()
    let tileShadow=NSShadow();tileShadow.shadowColor=color(38,38,48,0.16);tileShadow.shadowBlurRadius=17;tileShadow.shadowOffset=NSSize(width:0,height:-9);tileShadow.set()
    color(241,236,224).setFill();tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting:color(246,241,231),ending:color(255,253,247))!.draw(in:tile,angle:90)
    color(255,255,255,0.65).setStroke();tile.lineWidth=3;tile.stroke()

    // A quiet second leaf makes the mark feel like a place kept between pages.
    NSGraphicsContext.saveGraphicsState()
    let tilt=AffineTransform(translationByX:535,byY:522)
    var transform=tilt;transform.rotate(byDegrees:-10);transform.translate(x:-535,y:-522)
    let back=bookmark(NSRect(x:363,y:272,width:366,height:520),corner:49,notch:100)
    back.transform(using:transform)
    let leafShadow=NSShadow();leafShadow.shadowColor=color(87,63,36,0.12);leafShadow.shadowBlurRadius=18;leafShadow.shadowOffset=NSSize(width:2,height:-10);leafShadow.set()
    color(202,172,123).setFill();back.fill()
    NSGraphicsContext.restoreGraphicsState()

    let front=bookmark(NSRect(x:290,y:240,width:374,height:574),corner:57,notch:116)
    NSGraphicsContext.saveGraphicsState()
    let shadow=NSShadow();shadow.shadowColor=color(31,44,65,0.24);shadow.shadowBlurRadius=28;shadow.shadowOffset=NSSize(width:1,height:-17);shadow.set()
    color(36,54,78).setFill();front.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting:color(29,46,68),ending:color(53,73,101))!.draw(in:front,angle:90)
    if pixels>=32 {
        color(246,238,217).setStroke()
        for (y,width) in [(650.0,172.0),(578.0,112.0)] {
            let line=NSBezierPath();line.move(to:NSPoint(x:376,y:y));line.line(to:NSPoint(x:376+width,y:y));line.lineWidth=22;line.lineCapStyle = .round;line.stroke()
        }
    }
    return bitmap.representation(using:.png,properties:[:])!
}

guard CommandLine.arguments.count==2 else {fatalError("Usage: swift Tools/make-icon.swift <output.iconset>")}
let output=URL(fileURLWithPath:CommandLine.arguments[1])
try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
for points in [16,32,128,256,512] {
    for scale in [1,2] {
        let name="icon_\(points)x\(points)\(scale==2 ? "@2x":"").png"
        try drawIcon(points*scale).write(to:output.appendingPathComponent(name))
    }
}
