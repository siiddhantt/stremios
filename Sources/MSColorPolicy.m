#import "MSColorPolicy.h"
#import <math.h>
NSString *MSNormalizedColorHex(id value) {
    if (![value isKindOfClass:NSString.class] || [value length]>16) return @"";
    NSString *hex=[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([hex hasPrefix:@"#"]) hex=[hex substringFromIndex:1];
    if (hex.length!=6) return @"";
    for (NSUInteger i=0;i<6;i++) { unichar c=[hex characterAtIndex:i]; if (!((c>='0'&&c<='9')||(c>='A'&&c<='F')||(c>='a'&&c<='f'))) return @""; }
    return hex.uppercaseString;
}
uint32_t MSColorRGB(NSString *hex) { NSString *valid=MSNormalizedColorHex(hex); return valid.length?(uint32_t)strtoul(valid.UTF8String,NULL,16):0; }
static double MSLinear(double value) { return value<=0.04045?value/12.92:pow((value+0.055)/1.055,2.4); }
static double MSLuminance(uint32_t rgb) { return 0.2126*MSLinear(((rgb>>16)&255)/255.0)+0.7152*MSLinear(((rgb>>8)&255)/255.0)+0.0722*MSLinear((rgb&255)/255.0); }
double MSColorContrastRatio(uint32_t first,uint32_t second) { double a=MSLuminance(first),b=MSLuminance(second); return (fmax(a,b)+0.05)/(fmin(a,b)+0.05); }
static uint32_t MSBlendWhite(uint32_t rgb,double amount) { uint32_t result=0; for (int shift=0;shift<=16;shift+=8) { unsigned channel=(rgb>>shift)&255; result|=(uint32_t)ceil(channel+(255-channel)*amount)<<shift; } return result; }
static NSString *MSReadableHex(NSString *hex,uint32_t background,NSString *fallback) {
    NSString *valid=MSNormalizedColorHex(hex); if (!valid.length) return fallback;
    uint32_t rgb=MSColorRGB(valid); if (MSColorContrastRatio(rgb,background)>=4.5) return valid;
    double low=0,high=1; for (int i=0;i<20;i++) { double middle=(low+high)/2; if (MSColorContrastRatio(MSBlendWhite(rgb,middle),background)>=4.5) high=middle; else low=middle; }
    return [NSString stringWithFormat:@"%06X",MSBlendWhite(rgb,high)];
}
NSString *MSReadableAccentHex(NSString *hex) { return MSReadableHex(hex,0x1A1C24,@"B6AFFF"); }
NSString *MSReadableSubtitleHex(NSString *hex) { return MSReadableHex(hex,0x000000,@"FFFFFF"); }
