//
//  WBBladesScanManager.m
//  WBBlades
//
//  Created by 邓竹立 on 2019/6/14.
//  Copyright © 2019 邓竹立. All rights reserved.
//

#import "WBBladesScanManager.h"
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/vm_map.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>
#import "WBBladesObjectHeader.h"
#import "WBBladesSymTab.h"
#import "WBBladesStringTab.h"
#import "WBBladesObject.h"
#import "WBBladesLinkManager.h"
#import <mach-o/nlist.h>
#import "WBBladesClassDefine.h"
#import "capstone.h"
#import <objc/runtime.h>

#define NSSTRING(C_STR) [NSString stringWithCString: (char *)(C_STR) encoding: [NSString defaultCStringEncoding]]
#define CSTRING(NS_STR) [(NS_STR) cStringUsingEncoding: [NSString defaultCStringEncoding]]

struct class64 {
    unsigned long long isa;
    unsigned long long superClass;
    unsigned long long cache;
    unsigned long long vtable;
    unsigned long long data;
    
};

struct cfstring64 {
    unsigned long long ptr;
    unsigned long long unknown;
    unsigned long long stringAddress;
    unsigned long long size;
    
};

struct class64Info {
    unsigned int flags;
    unsigned int instanceStart;
    unsigned int instanceSize;
    unsigned int reserved;
    unsigned long long  instanceVarLayout;
    unsigned long long  name;
    unsigned long long  baseMethods;
    unsigned long long  baseProtocols;
    unsigned long long  instanceVariables;
    unsigned long long  weakInstanceVariables;
    unsigned long long  baseProperties;
};

@implementation WBBladesScanManager

+ (unsigned long long)scanStaticLibrary:(NSData *)fileData{
    
    if (!fileData || ![self isSupport:fileData]) {
        return 0;
    }
    NSRange range = NSMakeRange(8, 0);
    WBBladesObjectHeader * symtabHeader = [self scanSymtabHeader:fileData range:range];
    
    range = NSMakeRange(NSMaxRange(symtabHeader.range), 0);
    WBBladesSymTab * symTab = [self scanSymbolTab:fileData range:range];
    
    range = NSMakeRange(NSMaxRange(symTab.range), 0);
    WBBladesStringTab * stringTab = [self scanStringTab:fileData range:range];
    
    range = NSMakeRange(NSMaxRange(stringTab.range), 0);
    
    NSMutableArray *objects = [NSMutableArray array];
    //循环扫描静态库中所有的目标文件
    while (range.location < fileData.length) {
        WBBladesObject *object = [self scanObject:fileData range:range];
        range = NSMakeRange(NSMaxRange(object.range), 0);
        [objects addObject:object];
        range = [self rangeAlign:range];
    }
    
    unsigned long long linkSize = [[WBBladesLinkManager shareInstance] linkWithObjects:objects];
    return linkSize;
}

+ (WBBladesObject *)scanObject:(NSData *)fileData range:(NSRange)range{
    range = [self rangeAlign:range];
    
    //扫描头
    WBBladesObject *object = [WBBladesObject  new];
    object.objectHeader = [self scanObjectHeader:fileData range:range];
    
    range = NSMakeRange(NSMaxRange(object.objectHeader.range), 0);
    //扫描Mach-O
    WBBladesObjectMachO *machO = [self scanObjectMachO:fileData range:range];
    object.objectMachO = machO;
    object.range = NSMakeRange(object.objectHeader.range.location, NSMaxRange(machO.range) - object.objectHeader.range.location);
    return object;
}

+ (WBBladesObjectHeader *)scanObjectHeader:(NSData *)fileData range:(NSRange)range{
    
    NSRange tmpRange = range;
    NSUInteger len = fileData.length - tmpRange.location;
    //为了复用符号表的获取代码,截取二进制
    NSData *tmpData = [self read_bytes:tmpRange length:len fromFile:fileData];
    NSRange headerRange = NSMakeRange(0, 0);
    WBBladesObjectHeader * objcHeader = [self scanSymtabHeader:tmpData range:headerRange];
    objcHeader.range = NSMakeRange(range.location, objcHeader.range.length);
    //    NSLog(@"正在分析%@",objcHeader.longName);
    return objcHeader;
}

+ (WBBladesObjectMachO *)scanObjectMachO:(NSData *)fileData range:(NSRange)range{
    
    //字节对齐
    range = [self rangeAlign:range];
    
    //记录__TEXT 和 __DATA的大小
    WBBladesObjectMachO *objcMachO = [WBBladesObjectMachO new];
    objcMachO.sections = [NSMutableDictionary dictionary];
    //64位 mach-o 文件的magic number == 0XFEEDFACF
    unsigned int magicNum = 0;
    NSRange tmpRange = NSMakeRange(range.location, 4);
    [fileData getBytes:&magicNum range:tmpRange];
    if (magicNum != MH_MAGIC_64 && magicNum != MH_CIGAM_64) {
        NSLog(@"暂时不处理非64位文件");
        exit(0);
    }
    
    //获取mach-o header
    mach_header_64 mhHeader;
    tmpRange = NSMakeRange(range.location, sizeof(mach_header_64));
    [fileData getBytes:&mhHeader range:tmpRange];
    unsigned long long mhHeaderLocation = range.location;
    unsigned long long stringTabEnd = mhHeaderLocation;
    
    //获取load command
    unsigned long long lcLocation = range.location + sizeof(mach_header_64);
    unsigned long long currentLcLocation = lcLocation;
    
    //遍历load command
    for (int i = 0; i < mhHeader.ncmds; i++) {
        
        load_command* cmd = (load_command *)malloc(sizeof(load_command));
        [fileData getBytes:cmd range:NSMakeRange(currentLcLocation, sizeof(load_command))];
        
        if (cmd->cmd == LC_SEGMENT_64) {//LC_SEGMENT_64:(section header....)
            
            segment_command_64 segmentCommand;
            [fileData getBytes:&segmentCommand range:NSMakeRange(currentLcLocation, sizeof(segment_command_64))];
            
            unsigned long long currentSecLocation = currentLcLocation + sizeof(segment_command_64);
            
            //遍历所有的section header
            for (int j = 0; j < segmentCommand.nsects; j++) {
                
                section_64 sectionHeader;
                [fileData getBytes:&sectionHeader range:NSMakeRange(currentSecLocation, sizeof(section_64))];
                NSString *segName = [[NSString alloc] initWithUTF8String:sectionHeader.segname];
                
                //获取section 信息，__TEXT 和 __DATA的大小统计到应用中
                if ([segName isEqualToString:@"__TEXT"] ||
                    [segName isEqualToString:@"__DATA"]) {
                    
                    //                    NSString *sectionName = [NSString stringWithFormat:@"(%@,%s)",segName,sectionHeader.sectname];
                    //                    NSLog(@"------- %@ -------%llu",sectionName,sectionHeader.size);
                    objcMachO.size += sectionHeader.size;
                }
                
                //__TEXT的section 做存储，用于虚拟链接
                if ([segName isEqualToString:@"__TEXT"] ||
                    [segName isEqualToString:@"__DATA"]) {
                    
                    //跳转到相应的section
                    unsigned int secOffset = sectionHeader.offset;
                    unsigned long long  secLocation = mhHeaderLocation + secOffset;
                    NSString *sectionName = [NSString stringWithFormat:@"(%@,%s)",segName,sectionHeader.sectname];
                    NSRange secRange = NSMakeRange(secLocation, 0);
                    
                    //获取section 内容
                    switch (sectionHeader.flags & SECTION_TYPE) {
                        case S_CSTRING_LITERALS:{
                            
                            NSArray *array = [self read_strings:secRange fixlen:sectionHeader.size fromFile:fileData];
                            [objcMachO.sections setObject:array forKey:sectionName];
                        }
                            break;
                        case S_4BYTE_LITERALS:{
                            NSMutableArray *array = [NSMutableArray array];
                            for (int k = 0; k < sectionHeader.size / 4; k++) {
                                NSData *literals = [self read_bytes:secRange length:4 fromFile:fileData];
                                if (literals) {
                                    [array addObject:literals];
                                    //                                    NSLog(@"4字节常量：%@",literals);
                                }
                            }
                            [objcMachO.sections setObject:[array copy] forKey:sectionName];
                            
                        }
                            break;
                        case S_8BYTE_LITERALS:{
                            NSMutableArray *array = [NSMutableArray array];
                            for (int k = 0; k < sectionHeader.size / 8; k++) {
                                NSData *literals = [self read_bytes:secRange length:8 fromFile:fileData];
                                if (literals) {
                                    [array addObject:literals];
                                    //                                    NSLog(@"8字节常量：%@",literals);
                                }
                            }
                            [objcMachO.sections setObject:[array copy] forKey:sectionName];
                        }
                            break;
                        case S_16BYTE_LITERALS:{
                            NSMutableArray *array = [NSMutableArray array];
                            for (int k = 0; k < sectionHeader.size / 16; k++) {
                                NSData *literals = [self read_bytes:secRange length:16 fromFile:fileData];
                                if (literals) {
                                    [array addObject:literals];
                                    //                                    NSLog(@"16字节常量：%@",literals);
                                }
                            }
                            [objcMachO.sections setObject:[array copy] forKey:sectionName];
                        }
                            break;
                            
                        case S_REGULAR:{
                            if ([sectionName isEqualToString:@"(__TEXT,__ustring)"]) {
                                //获取中文字符串
                                NSData *data = [self read_bytes:secRange length:sectionHeader.size fromFile:fileData];
                                
                                unsigned short *head = (unsigned short *)[data bytes];
                                unsigned short *start = head;
                                unsigned short *end = head;
                                NSMutableArray *array = [NSMutableArray array];
                                
                                while (start <= head + (data.length)/sizeof(short)) {
                                    if (* end == 0x0000) {
                                        unsigned long size = (end - start)*sizeof(short)+sizeof(short);
                                        NSData *tmp = [NSData dataWithBytes:start length:size];
                                        NSString *uString = [[NSString alloc] initWithData:tmp encoding:NSUTF16LittleEndianStringEncoding];
                                        start = end + 1;
                                        if (uString.length>0) {
                                            [array addObject:uString];
                                        }
                                    }
                                    end ++;
                                }
                                [objcMachO.sections setObject:[array copy] forKey:sectionName];
                            }
                        }
                        default:
                            break;
                    }
                }
                
                currentSecLocation += sizeof(section_64);
            }
        }else if (cmd->cmd == LC_SYMTAB){//查找字符串表
            
            //根据字符串的尾部 确定当前mach-o的尾部
            symtab_command symtabCommand;
            [fileData getBytes:&symtabCommand range:NSMakeRange(currentLcLocation, sizeof(symtab_command))];
            stringTabEnd = mhHeaderLocation + symtabCommand.stroff + symtabCommand.strsize;
            
            //加上字符串表和符号表的大小
            //            objcMachO.size += symtabCommand.strsize;
            //            objcMachO.size += symtabCommand.nsyms * (sizeof(nlist_64));
            
            
            //保存符号表和字符串表的关键数据，用于虚拟链接
            //            NSRange tmpRange = NSMakeRange(mhHeaderLocation + symtabCommand.stroff, 0);
            //            objcMachO.stringTab = (char *)((char*)[fileData bytes] + mhHeaderLocation + symtabCommand.stroff);
            //            objcMachO.stringSize = symtabCommand.strsize;
            //            tmpRange = NSMakeRange(mhHeaderLocation + symtabCommand.symoff, symtabCommand.nsyms * sizeof(nlist_64));
            //            nlist_64 *symbolList = (nlist_64 *)malloc(symtabCommand.nsyms * sizeof(nlist_64));
            //            [fileData getBytes:symbolList range:tmpRange];
            //            NSMutableArray *indexList = [NSMutableArray array];
            //            for (int j = 0; j<symtabCommand.nsyms; j++) {
            //                nlist_64 symbol = symbolList[j];
            //                NSDictionary *symbolIndex = @{
            //                                              @"index":@(symbol.n_un.n_strx),
            //                                              @"type":@(symbol.n_type)
            //                                              };
            //                [indexList addObject:symbolIndex];
            //            }
            //            objcMachO.symbolTab = [indexList copy];
            //            free(symbolList);
        }
        
        currentLcLocation += cmd->cmdsize;
        
        free(cmd);
    }
    
    objcMachO.range = NSMakeRange(mhHeaderLocation, stringTabEnd - mhHeaderLocation);
    
    return objcMachO;
}

//扫描符号表
+ (WBBladesSymTab *)scanSymbolTab:(NSData *)fileData range:(NSRange)range{
    range = [self rangeAlign:range];
    unsigned long long location = range.location;
    WBBladesSymTab *symTab = [WBBladesSymTab new];
    
    //获取符号表大小
    NSData *data = [self read_bytes:range length:4 fromFile:fileData];
    unsigned int size = 0;
    [data getBytes:&size range:NSMakeRange(0, 4)];
    symTab.size = size;
    
    //获取符号表
    NSMutableArray *symbols = [NSMutableArray array];
    unsigned int symbolCount = (symTab.size - sizeof(unsigned int))/8;
    for (int i = 0; i < symbolCount; i++) {
        WBBladesSymbol *symbol = [WBBladesSymbol new];
        NSData * indexData = [self read_bytes:range length:4 fromFile:fileData];
        unsigned int index = 0;
        [indexData getBytes:&index range:NSMakeRange(0, 4)];
        
        unsigned int offset = 0;
        NSData *offsetData = [self read_bytes:range length:4 fromFile:fileData];
        [offsetData getBytes:&offset range:NSMakeRange(0, 4)];
        
        [symbols addObject:symbol];
    }
    symTab.symbols = [symbols copy];
    symTab.range = NSMakeRange(location, size + sizeof(unsigned int));//size 不包括自身的4字节，所以需要 + 4
    return symTab;
}

//扫描字符串表
+ (WBBladesStringTab *)scanStringTab:(NSData *)fileData range:(NSRange) range{
    
    //字符串表不存在字节对齐
    unsigned long long location = range.location;
    
    WBBladesStringTab *stringTab = [WBBladesStringTab new];
    //获取字符串表大小
    NSData *data = [self read_bytes:range length:4 fromFile:fileData];
    unsigned int size = 0;
    [data getBytes:&size range:NSMakeRange(0, 4)];
    
    //获取所有的字符串信息
    stringTab.strings = [self read_strings:range fixlen:size fromFile:fileData];
    
    //同理，字符串表长度也不包含自身4字节
    stringTab.range = NSMakeRange(location, size + sizeof(unsigned int));
    return stringTab;
}

//扫描符号表头
+ (WBBladesObjectHeader *)scanSymtabHeader:(NSData *)fileData range:(NSRange )range{
    
    range = [self rangeAlign:range];
    unsigned long long location = range.location;
    
    WBBladesObjectHeader *header = [[WBBladesObjectHeader alloc] init];
    
    header.name = [self read_string:range fixlen:16 fromFile:fileData];
    header.timeStamp = [self read_string:range fixlen:12 fromFile:fileData];
    header.userID = [self read_string:range fixlen:6 fromFile:fileData];
    header.groupID = [self read_string:range fixlen:6 fromFile:fileData];
    header.mode = [self read_string:range fixlen:8 fromFile:fileData];
    header.size = [self read_string:range fixlen:8 fromFile:fileData];
    NSMutableString * padding = [[NSMutableString alloc] initWithCapacity:2];
    
    for(;;){
        [padding appendString:[self read_string:range fixlen:1 fromFile:fileData]];
        if (*(CSTRING(padding) + [padding length] - 1) != ' '){
            [padding appendString:[self read_string:range fixlen:1 fromFile:fileData]];
            break;
        }
    }
    header.endHeader = padding;
    if (NSEqualRanges([header.name rangeOfString:@"#1/"], NSMakeRange(0,3))){
        uint32_t len = [[header.name substringFromIndex:3] intValue];
        header.longName = [self read_string:range fixlen:len fromFile:fileData];
    }
    header.range = NSMakeRange(location, NSMaxRange(range) - location);
    return header;
}

//字节对齐
+ (NSRange)rangeAlign:(NSRange)range{
    unsigned long long location = NSMaxRange(range);
    location = 8 * ceil(location / 8.0);
    return NSMakeRange(location, range.length);
}

+ (BOOL)isSupport:(NSData *)fileData{
    uint32_t magic = *(uint32_t*)((uint8_t *)[fileData bytes]);
    switch (magic)
    {
        case FAT_MAGIC:
        case FAT_CIGAM:
        {
            NSLog(@"fat binary");
        } break;
            
        case MH_MAGIC:
        case MH_CIGAM:
        {
            NSLog(@"32位 mach-o");
        } break;
            
        case MH_MAGIC_64:
        case MH_CIGAM_64:
        {
            NSLog(@"64位 mach-o");
        } break;
        default:
        {
            if (*(uint64_t*)((uint8_t *)[fileData bytes]) == *(uint64_t*)"!<arch>\n"){
                NSLog(@"符合单架构静态库特征");
                return YES;
            }else{
                NSLog(@"非Mach-O文件");
            }
        }
    }
    return NO;
}

static cs_insn *s_cs_insn;
static section_64 textList = {0};

+ (void)scanAllClassWithFileData:(NSData*)fileData{
    
    unsigned long long max = [fileData length];
    mach_header_64 mhHeader;
    [fileData getBytes:&mhHeader range:NSMakeRange(0, sizeof(mach_header_64))];
    
    section_64 classList = {0};
    section_64 selrefList = {0};
    section_64 classrefList= {0};
    section_64 nlclsList= {0};
    section_64 cfstringList= {0};
    
    unsigned long long currentLcLocation = sizeof(mach_header_64);
    for (int i = 0; i < mhHeader.ncmds; i++) {
        load_command* cmd = (load_command *)malloc(sizeof(load_command));
        [fileData getBytes:cmd range:NSMakeRange(currentLcLocation, sizeof(load_command))];
        if (cmd->cmd == LC_SEGMENT_64) {//LC_SEGMENT_64:(section header....)
            
            segment_command_64 segmentCommand;
            [fileData getBytes:&segmentCommand range:NSMakeRange(currentLcLocation, sizeof(segment_command_64))];
            NSString *segName = [NSString stringWithFormat:@"%s",segmentCommand.segname];
            
            if ([segName isEqualToString:@"__DATA"]) {
                //遍历所有的section header
                unsigned long long currentSecLocation = currentLcLocation + sizeof(segment_command_64);
                for (int j = 0; j < segmentCommand.nsects; j++) {
                    
                    section_64 sectionHeader;
                    [fileData getBytes:&sectionHeader range:NSMakeRange(currentSecLocation, sizeof(section_64))];
                    NSString *secName = [[NSString alloc] initWithUTF8String:sectionHeader.sectname];
                    
                    if ([secName isEqualToString:@"__objc_classlist__DATA"]) {
                        classList = sectionHeader;
                    }
                    if ([secName isEqualToString:@"__objc_selrefs"]) {
                        selrefList = sectionHeader;
                    }
                    if ([secName isEqualToString:@"__objc_classrefs__DATA"]) {
                        classrefList = sectionHeader;
                    }
                    if ([secName isEqualToString:@"__objc_nlclslist__DATA"]) {
                        nlclsList = sectionHeader;
                    }
                    if ([secName isEqualToString:@"__cfstring"]) {
                        cfstringList = sectionHeader;
                    }
                    currentSecLocation += sizeof(section_64);
                }
            }
            else if ([segName isEqualToString:@"__TEXT"]){
                unsigned long long currentSecLocation = currentLcLocation + sizeof(segment_command_64);
                for (int j = 0; j < segmentCommand.nsects; j++) {
                    
                    section_64 sectionHeader;
                    [fileData getBytes:&sectionHeader range:NSMakeRange(currentSecLocation, sizeof(section_64))];
                    NSString *secName = [[NSString alloc] initWithUTF8String:sectionHeader.sectname];
                    
                    if ([secName isEqualToString:@"__text"]) {
                        textList = sectionHeader;
                        s_cs_insn = [self scanAllASMWithfileData:fileData begin:sectionHeader.offset size:sectionHeader.size vmBase:0];
                    }
                    
                    currentSecLocation += sizeof(section_64);
                }
            }
        }
        currentLcLocation += cmd->cmdsize;
        free(cmd);
    }
    unsigned long long vm = classList.addr - classList.offset;
    
    NSMutableSet *classrefSet = [NSMutableSet set];
    NSMutableDictionary *selrefDic = [NSMutableDictionary dictionary];
    
    //获取selref
    NSRange range = NSMakeRange(selrefList.offset, 0);
    for (int i = 0; i < selrefList.size / 8; i++) {
        
        @autoreleasepool {
            unsigned long long selAddress;
            NSData *data = [self read_bytes:range length:8 fromFile:fileData];
            [data getBytes:&selAddress range:NSMakeRange(0, 8)];
            selAddress = selAddress - vm;
            //方法名最大150字节
            uint8_t * buffer = (uint8_t *)malloc(150 + 1); buffer[150] = '\0';
            if (selAddress < max) {
                
                [fileData getBytes:buffer range:NSMakeRange(selAddress,150)];
                NSString * selName = NSSTRING(buffer);
                
                if (selName) {
                    WBBladesHelper *helper = [WBBladesHelper new];
                    helper.selName = selName;
                    helper.offset = selrefList.offset + i*8;
                    [selrefDic setObject:helper forKey:selName];
                }
            }
            free(buffer);
        }
    }
    
    //获取nlclslist
    range = NSMakeRange(nlclsList.offset, 0);
    for (int i = 0; i < nlclsList.size / 8; i++) {
        @autoreleasepool {
            
            unsigned long long classAddress;
            NSData *data = [self read_bytes:range length:8 fromFile:fileData];
            [data getBytes:&classAddress range:NSMakeRange(0, 8)];
            classAddress = classAddress - vm;
            //方法名最大150字节
            if (classAddress < max) {
                
                class64 targetClass;
                [fileData getBytes:&targetClass range:NSMakeRange(classAddress,sizeof(class64))];
                
                class64Info targetClassInfo = {0};
                unsigned long long targetClassInfoOffset = targetClass.data - vm;
                NSRange targetClassInfoRange = NSMakeRange(targetClassInfoOffset, 0);
                data = [self read_bytes:targetClassInfoRange length:sizeof(class64Info) fromFile:fileData];
                [data getBytes:&targetClassInfo length:sizeof(class64Info)];
                unsigned long long classNameOffset = targetClassInfo.name - vm;
                
                //类名最大50字节
                uint8_t * buffer = (uint8_t *)malloc(50 + 1); buffer[50] = '\0';
                [fileData getBytes:buffer range:NSMakeRange(classNameOffset, 50)];
                NSString * className = NSSTRING(buffer);
                free(buffer);
                if (className) {
                    [classrefSet addObject:className];
                }
            }
            
        }
    }
    
    //获取classref
    range = NSMakeRange(classrefList.offset, 0);
    for (int i = 0; i < classrefList.size / 8; i++) {
        @autoreleasepool {
            
            unsigned long long classAddress;
            NSData *data = [self read_bytes:range length:8 fromFile:fileData];
            [data getBytes:&classAddress range:NSMakeRange(0, 8)];
            classAddress = classAddress - vm;
            //方法名最大150字节
            if (classAddress < max) {
                
                class64 targetClass;
                ptrdiff_t off = classAddress;
                char * p = (char *)fileData.bytes;
                p = p+off;
                memcpy(&targetClass, p, sizeof(class64));
                
                class64Info targetClassInfo = {0};
                unsigned long long targetClassInfoOffset = targetClass.data - vm;
                NSRange targetClassInfoRange = NSMakeRange(targetClassInfoOffset, 0);
                data = [self read_bytes:targetClassInfoRange length:sizeof(class64Info) fromFile:fileData];
                [data getBytes:&targetClassInfo length:sizeof(class64Info)];
                unsigned long long classNameOffset = targetClassInfo.name - vm;
                
                //类名最大50字节
                uint8_t * buffer = (uint8_t *)malloc(50 + 1); buffer[50] = '\0';
                [fileData getBytes:buffer range:NSMakeRange(classNameOffset, 50)];
                NSString * className = NSSTRING(buffer);
                free(buffer);
                if (className) {
                    WBBladesHelper *helper = [WBBladesHelper new];
                    helper.className = className;
                    helper.selName = @"";
                    helper.offset = range.location;
                    
                    if (
                        [className hasPrefix:@"WB"] ||
                        [className hasPrefix:@"AJK"] ||
                        [className hasPrefix:@"AHS"] ||
                        [className hasPrefix:@"AIF"] ||
                        [className hasPrefix:@"AF"] ||
                        [className hasPrefix:@"UsedCar"] ||
                        [className hasPrefix:@"UC"] ||
                        [className hasPrefix:@"SCH"] ||
                        [className hasPrefix:@"HS"] ||
                        [className hasPrefix:@"HL"] ||
                        [className hasPrefix:@"ZX"] ) {
                        NSLog(@" %i 校验%@",i,className);
                        if ([self scanSymbolTabWithFileData:fileData helper:helper]) {
                            [classrefSet addObject:className];
                        }
                    }else{
                        [classrefSet addObject:className];
                    }
                }
            }
        }
    }
    //
    //获取cfstring
    range = NSMakeRange(cfstringList.offset, 0);
    for (int i = 0; i < cfstringList.size / sizeof(cfstring64); i++) {
        @autoreleasepool {
            
            cfstring64 cfstring;
            NSData *data = [self read_bytes:range length:sizeof(cfstring64) fromFile:fileData];
            [data getBytes:&cfstring range:NSMakeRange(0, sizeof(cfstring64))];
            unsigned long long stringOff = cfstring.stringAddress - vm;
            //方法名最大150字节
            if (stringOff < max) {
                //类名最大50字节
                uint8_t * buffer = (uint8_t *)malloc(cfstring.size + 1); buffer[cfstring.size] = '\0';
                [fileData getBytes:buffer range:NSMakeRange(stringOff, cfstring.size)];
                NSString * className = NSSTRING(buffer);
                free(buffer);
                if (className){
                    [classrefSet addObject:className];
                }
            }
        }
        
    }
    
    //获取所有类classlist
    NSMutableSet *classSet = [NSMutableSet set];
    range = NSMakeRange(classList.offset, 0);
    for (int i = 0; i < classList.size / 8 ; i++) {
        @autoreleasepool {
            
            unsigned long long classAddress;
            NSData *data = [self read_bytes:range length:8 fromFile:fileData];
            [data getBytes:&classAddress range:NSMakeRange(0, 8)];
            unsigned long long classOffset = classAddress - vm;
            
            class64 targetClass = {0};
            NSRange targetClassRange = NSMakeRange(classOffset, 0);
            data = [self read_bytes:targetClassRange length:sizeof(class64) fromFile:fileData];
            [data getBytes:&targetClass length:sizeof(class64)];
            
            class64Info targetClassInfo = {0};
            unsigned long long targetClassInfoOffset = targetClass.data - vm;
            NSRange targetClassInfoRange = NSMakeRange(targetClassInfoOffset, 0);
            data = [self read_bytes:targetClassInfoRange length:sizeof(class64Info) fromFile:fileData];
            [data getBytes:&targetClassInfo length:sizeof(class64Info)];
            unsigned long long classNameOffset = targetClassInfo.name - vm;
            
//            class64 metaClass = {0};
//            NSRange metaClassRange = NSMakeRange(targetClass.isa - vm, 0);
//            data = [self read_bytes:metaClassRange length:sizeof(class64) fromFile:fileData];
//            [data getBytes:&metaClass length:sizeof(class64)];
//
//            class64Info metaClassInfo = {0};
//            unsigned long long metaClassInfoOffset = metaClass.data - vm;
//            NSRange metaClassInfoRange = NSMakeRange(metaClassInfoOffset, 0);
//            data = [self read_bytes:metaClassInfoRange length:sizeof(class64Info) fromFile:fileData];
//            [data getBytes:&metaClassInfo length:sizeof(class64Info)];
//
            if (targetClass.superClass != 0) {
                class64 superClass = {0};
                NSRange superClassRange = NSMakeRange(targetClass.superClass - vm, 0);
                data = [self read_bytes:superClassRange length:sizeof(class64) fromFile:fileData];
                [data getBytes:&superClass length:sizeof(class64)];
                
                class64Info superClassInfo = {0};
                unsigned long long superClassInfoOffset = superClass.data - vm;
                NSRange superClassInfoRange = NSMakeRange(superClassInfoOffset, 0);
                data = [self read_bytes:superClassInfoRange length:sizeof(class64Info) fromFile:fileData];
                [data getBytes:&superClassInfo length:sizeof(class64Info)];
                unsigned long long superClassNameOffset = superClassInfo.name - vm;
                
                //类名最大50字节
                uint8_t * buffer = (uint8_t *)malloc(50 + 1); buffer[50] = '\0';
                [fileData getBytes:buffer range:NSMakeRange(superClassNameOffset, 50)];
                NSString * superClassName = NSSTRING(buffer);
                free(buffer);
                if (superClassName) {
                    [classrefSet addObject:superClassName];
                }
            }
            
//            unsigned long long methodListOffset = targetClassInfo.baseMethods - vm;
//            unsigned long long classMethodListOffset = metaClassInfo.baseMethods - vm;
            
            //类名最大50字节
            uint8_t * buffer = (uint8_t *)malloc(50 + 1); buffer[50] = '\0';
            [fileData getBytes:buffer range:NSMakeRange(classNameOffset, 50)];
            NSString * className = NSSTRING(buffer);
            free(buffer);
            
            if (
                ![className hasPrefix:@"WB"] &&
                ![className hasPrefix:@"AJK"] &&
                ![className hasPrefix:@"AHS"] &&
                ![className hasPrefix:@"AIF"] &&
                ![className hasPrefix:@"AF"] &&
                ![className hasPrefix:@"UsedCar"] &&
                ![className hasPrefix:@"UC"] &&
                ![className hasPrefix:@"SCH"] &&
                ![className hasPrefix:@"HS"] &&
                ![className hasPrefix:@"HL"] &&
                ![className hasPrefix:@"ZX"] ) {
                NSLog(@"排除%@",className);
                continue;
            }
            NSLog(@"正在排查 %@",className);
            [classSet addObject:className];
            
            //遍历成员变量
            unsigned long long varListOffset = targetClassInfo.instanceVariables - vm;
            if (varListOffset < max) {
                unsigned int varCount;
                NSRange varRange = NSMakeRange(varListOffset+4, 0);
                data = [self read_bytes:varRange length:4 fromFile:fileData];
                [data getBytes:&varCount length:4];
                for (int j = 0; j<varCount; j++) {
                    varRange = NSMakeRange(varListOffset+8 + 32 * j + 16, 0);
                    data = [self read_bytes:varRange length:8 fromFile:fileData];
                    unsigned long long methodNameOffset;
                    [data getBytes:&methodNameOffset length:8];
                    methodNameOffset = methodNameOffset - vm;
                    uint8_t * buffer = (uint8_t *)malloc(150 + 1); buffer[150] = '\0';
                    if (methodNameOffset < max) {
                    [fileData getBytes:buffer range:NSMakeRange(methodNameOffset,150)];
                    NSString * typeName = NSSTRING(buffer);
                        if (typeName) {
                            typeName = [typeName stringByReplacingOccurrencesOfString:@"@\"" withString:@""];
                            typeName = [typeName stringByReplacingOccurrencesOfString:@"\"" withString:@""];
                            [classrefSet addObject:typeName];
                        }
                    }
                }
            }
            
            //遍历每个class的method (实例方法)
//            if (methodListOffset < max) {
//
//                unsigned int methodCount;
//                NSRange methodRange = NSMakeRange(methodListOffset+4, 0);
//                data = [self read_bytes:methodRange length:4 fromFile:fileData];
//                [data getBytes:&methodCount length:4];
//                for (int j = 0; j<methodCount; j++) {
//
//                    //获取方法名
//                    methodRange = NSMakeRange(methodListOffset+8 + 24 * j, 0);
//                    data = [self read_bytes:methodRange length:8 fromFile:fileData];
//
//                    unsigned long long methodNameOffset;
//                    [data getBytes:&methodNameOffset length:8];
//                    methodNameOffset = methodNameOffset - vm;
//
//                    //方法名最大150字节
//                    uint8_t * buffer = (uint8_t *)malloc(150 + 1); buffer[150] = '\0';
//                    if (methodNameOffset < max) {
//
//                        [fileData getBytes:buffer range:NSMakeRange(methodNameOffset,150)];
//                        NSString * methodName = NSSTRING(buffer);
//
//                        //查看method 是否在selref中
//                        if (methodName && selrefDic[methodName] && ![[self methodWhitelist] containsObject:methodName]) {
//                            WBBladesHelper *helper = selrefDic[methodName];
//                            helper.className = className;
////                            [classSet removeObject:className];
//                            break;
//                        }
//                    }
//                    free(buffer);
//                }
//            }
            
//            if (classMethodListOffset < max) {
//
//                unsigned int methodCount;
//                NSRange methodRange = NSMakeRange(classMethodListOffset+4, 0);
//                data = [self read_bytes:methodRange length:4 fromFile:fileData];
//                [data getBytes:&methodCount length:4];
//                for (int j = 0; j<methodCount; j++) {
//
//                    //获取方法名
//                    methodRange = NSMakeRange(classMethodListOffset+8 + 24 * j, 0);
//                    data = [self read_bytes:methodRange length:8 fromFile:fileData];
//
//                    unsigned long long methodNameOffset;
//                    [data getBytes:&methodNameOffset length:8];
//                    methodNameOffset = methodNameOffset - vm;
//
//                    //方法名最大150字节
//                    uint8_t * buffer = (uint8_t *)malloc(150 + 1); buffer[150] = '\0';
//                    if (methodNameOffset < max) {
//
//                        [fileData getBytes:buffer range:NSMakeRange(methodNameOffset,150)];
//                        NSString * methodName = NSSTRING(buffer);
//
//                        //查看method 是否在selref中
//                        if (methodName && selrefDic[methodName] && ![[self methodWhitelist] containsObject:methodName]) {
//                            WBBladesHelper *helper = selrefDic[methodName];
//                            helper.className = className;
//                            if (YES) {
////                                [classSet removeObject:className];
//                                break;
//                            }
//                        }
//                    }
//                    free(buffer);
//                }
//            }
        }
    }
    [classrefSet enumerateObjectsUsingBlock:^(id  _Nonnull obj, BOOL * _Nonnull stop) {
        [classSet removeObject:obj];
    }];
    NSLog(@"-----------校验完成--------------");
    [classSet enumerateObjectsUsingBlock:^(id  _Nonnull obj, BOOL * _Nonnull stop) {
        NSLog(@"%@",obj);
    }];
}

+ (BOOL)inClassBlacklistCheck:(char *)className{
    
   char *array[] = {(char*)"SD",(char*)"ISD",(char*)"WIM",(char*)"Bugly",(char*)"DI",(char*)"GI",(char*)"IF",(char*)"BM",(char*)"LOTA",(char*)"QQ",(char*)"RSA",(char*)"RCT",(char*)"RTC",(char*)"Weibo",(char*)"Alipay",(char*)"FMD",(char*)"MJ"};
    for (int i = 0; i<17; i++) {
        char *str = array[i];
        if (strstr(className, str) == className) {
            return YES;
        }
    }
    return NO;
}

+ (NSArray *)methodWhitelist{
    return @[@"init",
             @"dealloc",
             @"copy",
             @"mutableCopy",
             @"initialize",
             @"willActivate",
             @"didDeactivate",
             @"initWithCoder:",
             @"loadView",
             @"viewDidLoad",
             @"viewWillAppear:",
             @"viewDidAppear:",
             @"viewWillDisappear:",
             @"viewDidDisappear:",
             @"viewWillLayoutSubviews",
             @"viewDidLayoutSubviews",
             @"didReceiveMemoryWarning",
             @"willMoveToParentViewController:",
             @"didMoveToParentViewController:",
             @"updateViewConstraints",
             
             @"initWithStyle:reuseIdentifier:",
             @"initWithCoder:",
             @"imageView",
             @"textLabel",
             @"detailTextLabel",
             @"contentView",
             @"reuseIdentifier",
             @"initWithFrame:",
             @"tableView:numberOfRowsInSection:",
             @"tableView:cellForRowAtIndexPath:",
             @"tableView:titleForHeaderInSection:",
             @"tableView:titleForFooterInSection:",
             @"tableView:canEditRowAtIndexPath:",
             @"tableView:canMoveRowAtIndexPath:",
             @"sectionIndexTitlesForTableView:",
             @"tableView:sectionForSectionIndexTitle:atIndex:",
             @"tableView:commitEditingStyle:forRowAtIndexPath:",
             @"tableView:moveRowAtIndexPath:toIndexPath:",
             ];
}

//
+ (WBBladesSymTabCommand *)symbolTabOffsetWithMachO:(NSData *)fileData{
    
    WBBladesSymTabCommand * symTabCommand = objc_getAssociatedObject(fileData, "sym");
    if (symTabCommand) {
        return symTabCommand;
    }
    //获取mach-o header
    mach_header_64 mhHeader;
    NSRange tmpRange = NSMakeRange(0, sizeof(mach_header_64));
    [fileData getBytes:&mhHeader range:tmpRange];
    
    //获取load command
    unsigned long long currentLcLocation = sizeof(mach_header_64);
    
    //遍历load command
    for (int i = 0; i < mhHeader.ncmds; i++) {
        
        load_command* cmd = (load_command *)malloc(sizeof(load_command));
        [fileData getBytes:cmd range:NSMakeRange(currentLcLocation, sizeof(load_command))];
        
        if (cmd->cmd == LC_SYMTAB){//查找字符串表
            
            //根据字符串的尾部 确定当前mach-o的尾部
            symtab_command symtab;
            [fileData getBytes:&symtab range:NSMakeRange(currentLcLocation, sizeof(symtab_command))];
            //
            WBBladesSymTabCommand *tmp = [[WBBladesSymTabCommand alloc] init];
            tmp.cmd = symtab.cmd;
            tmp.cmdsize = symtab.cmdsize;
            tmp.symbolOff = symtab.symoff;
            tmp.strOff = symtab.stroff;
            tmp.strSize = symtab.strsize;
            tmp.symbolNum = symtab.nsyms;
            
            objc_setAssociatedObject(fileData, "sym", tmp, OBJC_ASSOCIATION_RETAIN);
            return tmp;
        }
        currentLcLocation += cmd->cmdsize;
        free(cmd);
    }
    return nil;
}

+ (BOOL)scanSymbolTabWithFileData:(NSData *)fileData helper:(WBBladesHelper *)helper{
    
    unsigned long long vb = 0x100000000;
    
    WBBladesSymTabCommand *symCmd = [self symbolTabOffsetWithMachO:fileData];
    unsigned long long symbolOffset = symCmd.symbolOff;
    unsigned long long targetAddress = helper.offset;
    
    char *targetStr = (char *)[[[NSString stringWithFormat:@"#0x%llX",targetAddress] lowercaseString] cStringUsingEncoding:NSUTF8StringEncoding];
    char *targetHighStr =(char *) [[[NSString stringWithFormat:@"#0x%llX",targetAddress&0xFFFFFFFFFFFFF000] lowercaseString] cStringUsingEncoding:NSUTF8StringEncoding];
    char *targetLowStr = (char *)[[[NSString stringWithFormat:@"#0x%llX",targetAddress&0x0000000000000fff] lowercaseString] cStringUsingEncoding:NSUTF8StringEncoding];
    for (int i=0; i<symCmd.symbolNum - 1; i++) {
            nlist_64 nlist;
            ptrdiff_t off = symbolOffset + i * sizeof(nlist_64);
            char * p = (char *)fileData.bytes;
            p = p+off;
            memcpy(&nlist, p, sizeof(nlist_64));
            if (nlist.n_sect == 1 &&
                nlist.n_type == 0x0e) {
                
                char buffer[201];
                ptrdiff_t off = symCmd.strOff+nlist.n_un.n_strx;
                char * p = (char *)fileData.bytes;
                p = p+off;
                memcpy(&buffer, p, 200);
                
                char * className = strtok(buffer," ");
                className = strstr(className,"[");
                if (className) {
                    className = className+1;
                }else{
                    continue;
                }
                if (strcmp(className,[helper.className UTF8String]) == 0) {
                    continue;
                }
                
                //三方黑名单
                if ([self inClassBlacklistCheck:className]) {
                    continue;
                }
                
                unsigned long long begin = nlist.n_value;
                BOOL use = [self scanSELCallerWithAddress:targetStr heigh:targetHighStr low:targetLowStr begin:begin vb:vb];
                if (use) {
                    NSLog(@"%ld",i);
                    return YES;
                }
        }
    }
    return NO;
}

+ (BOOL)scanSELCallerWithAddress:(char * )targetStr heigh:(char *)targetHighStr low:(char *)targetLowStr  begin:(unsigned long long)begin  vb:(unsigned long long )vb{
    char * asmStr;
    BOOL high = NO;
    do {
            unsigned long long index = (begin - textList.offset - vb)/4;
            char *dataStr = s_cs_insn[index].op_str;
            asmStr = s_cs_insn[index].mnemonic;
            if (strcmp(".byte",asmStr) == 0) {
                return NO;
            }
            if (strstr(dataStr, targetStr)) {//直接命中
                return YES;
            }else if (strstr(dataStr, targetHighStr)) {//是否先命中高位
                high = YES;
            }else if (strstr(dataStr, targetLowStr)) {//是否在命中了高位后，命中了低12位
                if (high) {
                    return  YES;
                }
            }
            begin += 4;
    } while (strcmp("ret",asmStr) != 0);
    return NO;
    
}

+ (cs_insn * )scanAllASMWithfileData:(NSData *)fileData  begin:(unsigned long long)begin size:(unsigned long long )size vmBase:(unsigned long long)vmAddress{
    
    //获取汇编
    char * ot_sect = (char *)[fileData bytes] + begin - vmAddress;
    uint64_t ot_addr = begin ;
    csh cs_handle = 0;
    cs_insn *cs_insn = NULL;
    cs_err cserr;
    if ((cserr = cs_open(CS_ARCH_ARM64, CS_MODE_ARM, &cs_handle)) != CS_ERR_OK ){
        NSLog(@"Failed to initialize Capstone: %d, %s.", cserr, cs_strerror(cs_errno(cs_handle)));
        return NULL;
    }
    cs_option(cs_handle, CS_OPT_MODE, CS_MODE_ARM);
//        cs_option(cs_handle, CS_OPT_DETAIL, CS_OPT_ON);
    cs_option(cs_handle, CS_OPT_SKIPDATA, CS_OPT_ON);
    
    size_t disasm_count = cs_disasm(cs_handle, (const uint8_t *)ot_sect, size, ot_addr, 0, &cs_insn);
    if (disasm_count < 1 ) {
        NSLog(@"汇编指令解析不符合预期！");
        return NULL;
    }
    return cs_insn;
}

+ (NSArray *)read_strings:(NSRange &)range fixlen:(NSUInteger)len fromFile:(NSData *)fileData{
    range = NSMakeRange(NSMaxRange(range),len);
    NSMutableArray *strings = [NSMutableArray array];
    
    unsigned long size = 0;
    uint8_t * buffer = (uint8_t *)malloc(len + 1); buffer[len] = '\0';
    [fileData getBytes:buffer range:range];
    uint8_t *p = buffer;
    while (size < len) {
        NSString * str = NSSTRING(p);
        str = [self replaceEscapeCharsInString:str];
        if (str) {
            [strings addObject:str];
            //            NSLog(@"%@",str);
            //+1 是为了留出'\0'的位置
            size = [str length] + size + 1;
            p = p + [str length] + 1;
        }
    }
    free (buffer);
    return [strings copy];
}

//-----------------------------------------------------------------------------
+ (NSString *)read_string:(NSRange &)range fixlen:(NSUInteger)len fromFile:(NSData *)fileData
{
    range = NSMakeRange(NSMaxRange(range),len);
    uint8_t * buffer = (uint8_t *)malloc(len + 1); buffer[len] = '\0';
    [fileData getBytes:buffer range:range];
    NSString * str = NSSTRING(buffer);
    free (buffer);
    return [self replaceEscapeCharsInString:str];
}

//-----------------------------------------------------------------------------
+ (NSData *)read_bytes:(NSRange &)range length:(NSUInteger)length fromFile:(NSData *)fileData
{
    range = NSMakeRange(NSMaxRange(range),length);
    uint8_t * buffer = (uint8_t *)malloc(length);
    [fileData getBytes:buffer range:range];
    NSData * ret = [NSData dataWithBytes:buffer length:length];
    free (buffer);
    return ret;
}

//-----------------------------------------------------------------------------
+ (NSString *) replaceEscapeCharsInString: (NSString *)orig
{
    NSUInteger len = [orig length];
    NSMutableString * str = [[NSMutableString alloc] init];
    SEL sel = @selector(characterAtIndex:);
    unichar (*charAtIdx)(id, SEL, NSUInteger) = (typeof(charAtIdx)) [orig methodForSelector:sel];
    for (NSUInteger i = 0; i < len; i++)
    {
        unichar c = charAtIdx(orig, sel, i);
        switch (c)
        {
            default:    [str appendFormat:@"%C",c]; break;
            case L'\f': [str appendString:@"\\f"]; break; // form feed - new page (byte 0x0c)
            case L'\n': [str appendString:@"\\n"]; break; // line feed - new line (byte 0x0a)
            case L'\r': [str appendString:@"\\r"]; break; // carriage return (byte 0x0d)
            case L'\t': [str appendString:@"\\t"]; break; // horizontal tab (byte 0x09)
            case L'\v': [str appendString:@"\\v"]; break; // vertical tab (byte 0x0b)
        }
    }
    return str;
}

@end
