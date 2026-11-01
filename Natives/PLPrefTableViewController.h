#import <UIKit/UIKit.h>

typedef void(^CreateView)(UITableViewCell *, NSString *,NSString *, NSDictionary *);
typedef id (^GetPreferenceBlock)(NSString *, NSString *);
typedef void (^SetPreferenceBlock)(NSString *, NSString *, id);

@interface PLPrefTableViewController : UITableViewController<UITextFieldDelegate>

@property(nonatomic) CreateView typeButton, typeChildPane, typePickField, typeTextField, typeSlider, typeSwitch;

@property(nonatomic) GetPreferenceBlock getPreference;
@property(nonatomic) SetPreferenceBlock setPreference;
@property(nonatomic) BOOL prefSectionsVisible, hasDetail;
/// Show every section expanded with no collapsible header row (row 0 is a normal item). Used by the Settings category pages.
@property(nonatomic) BOOL flatSections;
/// Optional titles drawn above each section (parallel to prefSections)
@property(nonatomic) NSArray<NSString*>* prefSectionTitles;

@property(nonatomic) NSArray<NSString*>* prefSections;
@property(nonatomic) NSMutableArray<NSNumber*>* prefSectionsVisibility;
@property(nonatomic) NSArray<NSArray<NSDictionary*>*>* prefContents;
@property(nonatomic) BOOL prefDetailVisible;

- (UIBarButtonItem *)drawHelpButton;

@end
