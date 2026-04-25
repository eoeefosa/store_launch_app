import 'package:go_router/go_router.dart';
import 'package:store_launchfast/screens/auth/forgot_password_screen.dart';
import 'package:store_launchfast/screens/auth/login_screen.dart';
import 'package:store_launchfast/screens/auth/register_screen.dart';
import 'package:store_launchfast/screens/auth/awaiting_approval_screen.dart';
import 'package:store_launchfast/screens/dashboard/store_main_nav.dart';
import 'package:store_launchfast/screens/dashboard/worker_main_nav.dart';
import 'package:store_launchfast/splash_screen.dart';

final router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const StoreLaunchfastSplashScreen(),
    ),
    GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
    GoRoute(
      path: '/register',
      builder: (context, state) => const RegisterScreen(),
    ),
    GoRoute(
      path: '/forgot-password',
      builder: (context, state) => const ForgotPasswordScreen(),
    ),
    GoRoute(
      path: '/store',
      builder: (context, state) => const StoreMainNav(),
    ),
    GoRoute(
      path: '/worker',
      builder: (context, state) => const WorkerMainNav(),
    ),
    GoRoute(
      path: '/awaiting-approval',
      builder: (context, state) => const AwaitingApprovalScreen(),
    ),
  ],
);
