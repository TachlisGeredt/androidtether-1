#import <Cocoa/Cocoa.h>
#import <SystemConfiguration/SystemConfiguration.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    int active;
    int connected;
    char name[IFNAMSIZ];
    char ip[INET_ADDRSTRLEN];
    uint64_t rx;
    uint64_t tx;
} AwpIfInfo;

static int awp_feth_num(const char *name)
{
    char *end = NULL;
    long n;
    if (strncmp(name, "feth", 4) != 0 || name[4] == '\0')
        return -1;
    n = strtol(name + 4, &end, 10);
    if (!end || *end != '\0' || n < 0 || n > 1024)
        return -1;
    return (int)n;
}

static void awp_read_if(AwpIfInfo *out)
{
    struct ifaddrs *ifa = NULL, *p;
    int best = -1;
    memset(out, 0, sizeof *out);
    if (getifaddrs(&ifa) != 0)
        return;

    for (p = ifa; p; p = p->ifa_next) {
        int n = awp_feth_num(p->ifa_name);
        if (n < 0 || (n % 2) != 0)
            continue;
        if (!(p->ifa_flags & IFF_UP))
            continue;
        if (best < 0 || n < best) {
            best = n;
            strlcpy(out->name, p->ifa_name, sizeof out->name);
            out->active = 1;
        }
    }

    if (out->active) {
        for (p = ifa; p; p = p->ifa_next) {
            if (strcmp(p->ifa_name, out->name) != 0)
                continue;
            if (p->ifa_addr && p->ifa_addr->sa_family == AF_INET) {
                struct sockaddr_in *sin = (struct sockaddr_in *)p->ifa_addr;
                if ((ntohl(sin->sin_addr.s_addr) >> 16) != 0xA9FE) {
                    inet_ntop(AF_INET, &sin->sin_addr, out->ip, sizeof out->ip);
                    out->connected = 1;
                }
            } else if (p->ifa_addr && p->ifa_addr->sa_family == AF_LINK && p->ifa_data) {
                struct if_data *d = (struct if_data *)p->ifa_data;
                out->rx = d->ifi_ibytes;
                out->tx = d->ifi_obytes;
            }
        }
    }

    freeifaddrs(ifa);
}

static NSString *awp_fmt_bytes(uint64_t b)
{
    if (b >= 1024ULL * 1024ULL * 1024ULL)
        return [NSString stringWithFormat:@"%.2f GB", (double)b / (1024.0 * 1024.0 * 1024.0)];
    if (b >= 1024ULL * 1024ULL)
        return [NSString stringWithFormat:@"%.1f MB", (double)b / (1024.0 * 1024.0)];
    if (b >= 1024ULL)
        return [NSString stringWithFormat:@"%.0f KB", (double)b / 1024.0];
    return [NSString stringWithFormat:@"%llu B", (unsigned long long)b];
}

@interface AwpMenuBar : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property (strong) NSStatusItem *item;
@property (strong) NSMenu *menu;
@property (strong) NSMenuItem *miStatus;
@property (strong) NSMenuItem *miIface;
@property (strong) NSMenuItem *miIP;
@property (strong) NSMenuItem *miTraffic;
@property (copy) NSString *currentIP;
@property (strong) NSTimer *menuTimer;
@property (assign) SCDynamicStoreRef store;
@property (assign) CFRunLoopSourceRef rls;
- (void)refresh;
@end

static void awp_sc_cb(SCDynamicStoreRef store, CFArrayRef keys, void *info)
{
    (void)store;
    (void)keys;
    AwpMenuBar *self = (__bridge AwpMenuBar *)info;
    [self refresh];
}

@implementation AwpMenuBar

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    (void)note;

    self.item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"personalhotspot"
                              accessibilityDescription:@"Android USB Tethering"];
    if (icon) {
        NSImageSymbolConfiguration *cfg =
            [NSImageSymbolConfiguration configurationWithPointSize:15.0 weight:NSFontWeightRegular];
        icon = [icon imageWithSymbolConfiguration:cfg];
        [icon setTemplate:YES];
        self.item.button.image = icon;
    } else {
        self.item.button.title = @"USB";
    }
    self.item.visible = NO;

    self.menu = [[NSMenu alloc] initWithTitle:@"Android USB Tethering"];
    self.menu.autoenablesItems = NO;
    self.menu.delegate = self;

    NSMenuItem *hdr = [[NSMenuItem alloc] initWithTitle:@"Android USB Tethering"
                                                 action:nil
                                          keyEquivalent:@""];
    hdr.enabled = NO;
    [self.menu addItem:hdr];
    [self.menu addItem:[NSMenuItem separatorItem]];

    self.miStatus = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    self.miStatus.enabled = NO;
    [self.menu addItem:self.miStatus];

    self.miIface = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    self.miIface.enabled = NO;
    [self.menu addItem:self.miIface];

    self.miIP = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(copyIP:) keyEquivalent:@""];
    self.miIP.target = self;
    self.miIP.enabled = NO;
    self.miIP.hidden = YES;
    [self.menu addItem:self.miIP];

    self.miTraffic = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    self.miTraffic.enabled = NO;
    [self.menu addItem:self.miTraffic];

    self.item.menu = self.menu;

    SCDynamicStoreContext ctx = {0, (__bridge void *)self, NULL, NULL, NULL};
    self.store = SCDynamicStoreCreate(NULL, CFSTR("androidtether-ui"), awp_sc_cb, &ctx);
    if (self.store) {
        NSArray *keys = @[@"State:/Network/Interface", @"State:/Network/Global/IPv4"];
        NSArray *pats = @[@"State:/Network/Interface/feth.*/IPv4"];
        SCDynamicStoreSetNotificationKeys(self.store, (__bridge CFArrayRef)keys,
                                          (__bridge CFArrayRef)pats);
        self.rls = SCDynamicStoreCreateRunLoopSource(NULL, self.store, 0);
        if (self.rls)
            CFRunLoopAddSource(CFRunLoopGetMain(), self.rls, kCFRunLoopCommonModes);
    }

    [self refresh];
}

- (void)refresh
{
    AwpIfInfo info;
    awp_read_if(&info);

    if (!info.active) {
        self.item.visible = NO;
        self.currentIP = nil;
        return;
    }

    self.item.visible = YES;
    self.miStatus.title = info.connected ? @"Status: Connected" : @"Status: Connecting…";
    self.miIface.title = [NSString stringWithFormat:@"Interface: %s", info.name];

    if (info.connected) {
        self.currentIP = [NSString stringWithUTF8String:info.ip];
        self.miIP.title = [NSString stringWithFormat:@"IP: %@ (Copy)", self.currentIP];
        self.miIP.enabled = YES;
        self.miIP.hidden = NO;
    } else {
        self.currentIP = nil;
        self.miIP.enabled = NO;
        self.miIP.hidden = YES;
    }

    self.miTraffic.title = [NSString stringWithFormat:@"Traffic: ↓ %@  ↑ %@",
                            awp_fmt_bytes(info.rx), awp_fmt_bytes(info.tx)];
}

- (void)copyIP:(id)sender
{
    (void)sender;
    if (!self.currentIP.length)
        return;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:self.currentIP forType:NSPasteboardTypeString];
}

- (void)menuWillOpen:(NSMenu *)menu
{
    (void)menu;
    [self refresh];
    [self.menuTimer invalidate];
    self.menuTimer = [NSTimer timerWithTimeInterval:1.0
                                             target:self
                                           selector:@selector(refresh)
                                           userInfo:nil
                                            repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.menuTimer forMode:NSRunLoopCommonModes];
}

- (void)menuDidClose:(NSMenu *)menu
{
    (void)menu;
    [self.menuTimer invalidate];
    self.menuTimer = nil;
}

- (void)applicationWillTerminate:(NSNotification *)note
{
    (void)note;
    [self.menuTimer invalidate];
    if (self.rls) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), self.rls, kCFRunLoopCommonModes);
        CFRelease(self.rls);
        self.rls = NULL;
    }
    if (self.store) {
        CFRelease(self.store);
        self.store = NULL;
    }
}

@end

int main(void)
{
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        AwpMenuBar *delegate = [AwpMenuBar new];
        [app setDelegate:delegate];
        [app run];
    }
    return 0;
}
