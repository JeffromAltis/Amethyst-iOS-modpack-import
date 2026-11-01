#import "LauncherPillLabel.h"
#import "LauncherTheme.h"

@implementation LauncherPillLabel

+ (instancetype)pillWithText:(NSString *)text color:(UIColor *)color {
    LauncherPillLabel *pill = [LauncherPillLabel new];
    pill.text = text;
    pill.font = LauncherTheme.headerFont;
    pill.textColor = color;
    pill.backgroundColor = [color colorWithAlphaComponent:0.18];
    pill.layer.masksToBounds = YES;
    pill.textAlignment = NSTextAlignmentCenter;
    [pill setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [pill setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return pill;
}

- (void)drawTextInRect:(CGRect)rect {
    [super drawTextInRect:UIEdgeInsetsInsetRect(rect, UIEdgeInsetsMake(3, 10, 3, 10))];
}

- (CGSize)intrinsicContentSize {
    CGSize size = [super intrinsicContentSize];
    return CGSizeMake(size.width + 20, size.height + 6);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = self.bounds.size.height / 2;
}

@end
