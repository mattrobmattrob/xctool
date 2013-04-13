
#import "ApplicationTestRunner.h"

#import "LineReader.h"
#import "PJSONKit.h"
#import "SimulatorLauncher.h"
#import "TaskUtil.h"
#import "XcodeToolUtil.h"

@implementation ApplicationTestRunner

- (DTiPhoneSimulatorSessionConfig *)sessionForAppUninstaller:(NSString *)bundleID
{
  assert(bundleID != nil);
  
  NSString *sdkVersion = [_buildSettings[@"SDK_NAME"] stringByReplacingOccurrencesOfString:@"iphonesimulator" withString:@""];
  DTiPhoneSimulatorSystemRoot *systemRoot = [DTiPhoneSimulatorSystemRoot rootWithSDKVersion:sdkVersion];
  DTiPhoneSimulatorApplicationSpecifier *appSpec = [DTiPhoneSimulatorApplicationSpecifier specifierWithApplicationPath:
                                                    [PathToFBXcodetoolBinaries() stringByAppendingPathComponent:@"app-uninstaller.app"]];
  DTiPhoneSimulatorSessionConfig *sessionConfig = [[[DTiPhoneSimulatorSessionConfig alloc] init] autorelease];
  [sessionConfig setApplicationToSimulateOnStart:appSpec];
  [sessionConfig setSimulatedSystemRoot:systemRoot];
  // Always run as iPhone (family = 1)
  [sessionConfig setSimulatedDeviceFamily:@1];
  [sessionConfig setSimulatedApplicationShouldWaitForDebugger:NO];
  [sessionConfig setLocalizedClientName:@"xcodetool"];
  [sessionConfig setSimulatedApplicationLaunchArgs:@[bundleID]];
  return sessionConfig;
}

- (DTiPhoneSimulatorSessionConfig *)sessionConfigForRunningTestsWithEnvironment:(NSDictionary *)environment
                                                                     outputPath:(NSString *)outputPath
{
  NSString *testHostPath = [_buildSettings[@"TEST_HOST"] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
  NSString *testHostAppPath = [testHostPath stringByDeletingLastPathComponent];

  NSString *sdkVersion = [_buildSettings[@"SDK_NAME"] stringByReplacingOccurrencesOfString:@"iphonesimulator" withString:@""];
  NSString *appSupportDir = [NSString stringWithFormat:@"%@/Library/Application Support/iPhone Simulator/%@",
                             NSHomeDirectory(), sdkVersion];
  NSString *ideBundleInjectionLibPath = @"/../../Library/PrivateFrameworks/IDEBundleInjection.framework/IDEBundleInjection";
  NSString *testBundlePath = [NSString stringWithFormat:@"%@/%@", _buildSettings[@"BUILT_PRODUCTS_DIR"], _buildSettings[@"FULL_PRODUCT_NAME"]];
  
  DTiPhoneSimulatorSystemRoot *systemRoot = [DTiPhoneSimulatorSystemRoot rootWithSDKVersion:sdkVersion];
  DTiPhoneSimulatorApplicationSpecifier *appSpec =
  [DTiPhoneSimulatorApplicationSpecifier specifierWithApplicationPath:testHostAppPath];
  
  DTiPhoneSimulatorSessionConfig *sessionConfig = [[[DTiPhoneSimulatorSessionConfig alloc] init] autorelease];
  [sessionConfig setApplicationToSimulateOnStart:appSpec];
  [sessionConfig setSimulatedSystemRoot:systemRoot];
  // Always run as iPhone (family = 1)
  [sessionConfig setSimulatedDeviceFamily:@1];
  [sessionConfig setSimulatedApplicationShouldWaitForDebugger:NO];
  
  [sessionConfig setSimulatedApplicationLaunchArgs:@[
   @"-NSTreatUnknownArgumentsAsOpen", @"NO",
   @"-SenTestInvertScope", _senTestInvertScope ? @"YES" : @"NO",
   @"-SenTest", _senTestList,
   ]];
  NSMutableDictionary *launchEnvironment = [NSMutableDictionary dictionaryWithDictionary:@{
                                            @"CFFIXED_USER_HOME" : appSupportDir,
                                            @"DYLD_FRAMEWORK_PATH" : _buildSettings[@"TARGET_BUILD_DIR"],
                                            @"DYLD_LIBRARY_PATH" : _buildSettings[@"TARGET_BUILD_DIR"],
                                            @"DYLD_INSERT_LIBRARIES" : [@[
                                                                        [PathToFBXcodetoolBinaries() stringByAppendingPathComponent:@"otest-lib-ios.dylib"],
                                                                        ideBundleInjectionLibPath,
                                                                        ] componentsJoinedByString:@":"],
                                            @"DYLD_ROOT_PATH" : _buildSettings[@"SDKROOT"],
                                            @"IPHONE_SIMULATOR_ROOT" : _buildSettings[@"SDKROOT"],
                                            @"NSUnbufferedIO" : @"YES",
                                            @"XCInjectBundle" : testBundlePath,
                                            @"XCInjectBundleInto" : testHostPath,
                                            }];
  [launchEnvironment addEntriesFromDictionary:environment];
  [sessionConfig setSimulatedApplicationLaunchEnvironment:launchEnvironment];
  [sessionConfig setSimulatedApplicationStdOutPath:outputPath];
  [sessionConfig setSimulatedApplicationStdErrPath:outputPath];
  
  //[sessionConfig setLocalizedClientName:[NSString stringWithFormat:@"1234"]];
  [sessionConfig setLocalizedClientName:[NSString stringWithUTF8String:getprogname()]];
  
  return sessionConfig;
}

- (BOOL)uninstallApplication:(NSString *)bundleID
{
  assert(bundleID != nil);
  DTiPhoneSimulatorSessionConfig *config = [self sessionForAppUninstaller:bundleID];
  SimulatorLauncher *launcher = [[[SimulatorLauncher alloc] initWithSessionConfig:config] autorelease];

  return [launcher launchAndWaitForExit];
}

- (BOOL)runTestsInSimulator:(NSString *)testHostAppPath feedOutputToBlock:(void (^)(NSString *))feedOutputToBlock
{
  NSString *exitModePath = MakeTempFileWithPrefix(@"exit-mode");
  NSString *outputPath = MakeTempFileWithPrefix(@"output");
  NSFileHandle *outputHandle = [NSFileHandle fileHandleForReadingAtPath:outputPath];
  
  LineReader *reader = [[[LineReader alloc] initWithFileHandle:outputHandle] autorelease];
  reader.didReadLineBlock = feedOutputToBlock;

  DTiPhoneSimulatorSessionConfig *sessionConfig =
    [self sessionConfigForRunningTestsWithEnvironment:@{
     @"SAVE_EXIT_MODE_TO" : exitModePath,
     }
                                           outputPath:outputPath];
  
  [sessionConfig setSimulatedApplicationStdOutPath:outputPath];
  [sessionConfig setSimulatedApplicationStdErrPath:outputPath];
  
  SimulatorLauncher *launcher = [[[SimulatorLauncher alloc] initWithSessionConfig:sessionConfig] autorelease];
  
  [reader startReading];
  
  [launcher launchAndWaitForExit];
  
  [reader stopReading];
  [reader finishReadingToEndOfFile];
  
  NSDictionary *exitMode = [NSDictionary dictionaryWithContentsOfFile:exitModePath];
  
  [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:exitModePath error:nil];
  
  return [exitMode[@"via"] isEqualToString:@"exit"] && ([exitMode[@"status"] intValue] == 0);
}

- (BOOL)runIOSTestsAndFeedOutputTo:(void (^)(NSString *))outputLineBlock error:(NSString **)error
{
  // Sometimes the TEST_HOST will be wrapped in double quotes.
  NSString *testHostPath = [_buildSettings[@"TEST_HOST"] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
  NSString *testHostAppPath = [testHostPath stringByDeletingLastPathComponent];
  NSString *testHostPlistPath = [[testHostPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Info.plist"];
  NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:testHostPlistPath];
  NSString *testHostBundleID = plist[@"CFBundleIdentifier"];
  
  if (![self uninstallApplication:testHostBundleID]) {
    *error = [NSString stringWithFormat:@"Failed to uninstall the test host app '%@' before running tests.", testHostBundleID];
    return NO;
  }
  
  if (![self runTestsInSimulator:testHostAppPath feedOutputToBlock:outputLineBlock]) {
    *error = [NSString stringWithFormat:@"Failed to run tests"];
    return NO;
  }
  
  return YES;
}

- (BOOL)runOSXTestsAndFeedOutputTo:(void (^)(NSString *))outputLineBlock error:(NSString **)error
{
  NSString *testHostPath = _buildSettings[@"TEST_HOST"];
  
  // TODO: In Xcode, if you use GCC_ENABLE_OBJC_GC = supported, Xcode will run your test twice
  // with GC on and GC off.  We should eventually do the same.
  BOOL enableGC = ([_buildSettings[@"GCC_ENABLE_OBJC_GC"] isEqualToString:@"supported"] ||
                   [_buildSettings[@"GCC_ENABLE_OBJC_GC"] isEqualToString:@"required"]);

  NSArray *libraries = @[[PathToFBXcodetoolBinaries() stringByAppendingPathComponent:@"otest-lib-osx.dylib"],
                         [XcodeDeveloperDirPath() stringByAppendingPathComponent:@"Library/PrivateFrameworks/IDEBundleInjection.framework/IDEBundleInjection"],
                         ];
  
  NSTask *task = [[[NSTask alloc] init] autorelease];
  task.launchPath = testHostPath;
  task.arguments = @[@"-ApplePersistenceIgnoreState", @"YES",
                     @"-NSTreatUnknownArgumentsAsOpen", @"NO",
                     @"-SenTestInvertScope", _senTestInvertScope ? @"YES" : @"NO",
                     @"-SenTest", _senTestList,
                     ];
  task.environment = @{
                       @"DYLD_INSERT_LIBRARIES" : [libraries componentsJoinedByString:@":"],
                       @"DYLD_FRAMEWORK_PATH" : _buildSettings[@"BUILT_PRODUCTS_DIR"],
                       @"DYLD_LIBRARY_PATH" : _buildSettings[@"BUILT_PRODUCTS_DIR"],
                       @"DYLD_FALLBACK_FRAMEWORK_PATH" : [XcodeDeveloperDirPath() stringByAppendingPathComponent:@"Library/Frameworks"],
                       @"NSUnbufferedIO" : @"YES",
                       @"OBJC_DISABLE_GC" : !enableGC ? @"YES" : @"NO",
                       @"XCInjectBundle" : [_buildSettings[@"BUILT_PRODUCTS_DIR"] stringByAppendingPathComponent:_buildSettings[@"FULL_PRODUCT_NAME"]],
                       @"XCInjectBundleInto" : testHostPath,
                       };
  
  LaunchTaskAndFeedOuputLinesToBlock(task, outputLineBlock);
  
  return [task terminationStatus] == 0;
}

- (BOOL)runTestsAndFeedOutputTo:(void (^)(NSString *))outputLineBlock error:(NSString **)error
{
  NSString *sdkName = _buildSettings[@"SDK_NAME"];
  if ([sdkName hasPrefix:@"iphonesimulator"]) {
    return [self runIOSTestsAndFeedOutputTo:outputLineBlock error:error];
  } else if ([sdkName hasPrefix:@"macosx"]) {
    return [self runOSXTestsAndFeedOutputTo:outputLineBlock error:error];
  } else {
    NSAssert(FALSE, @"Unexpected SDK name: %@", sdkName);
    return NO;
  }
}

@end
